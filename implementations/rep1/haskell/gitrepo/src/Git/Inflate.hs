{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Git.Inflate
-- Description : A from-scratch DEFLATE (RFC 1951) and zlib (RFC 1950) decoder.
--
-- The decoder reports where the compressed stream ends, so streams stored
-- back to back (as in a packfile) can be told apart without knowing their
-- compressed lengths.
module Git.Inflate
  ( InflateError (..)
  , Inflated (..)
  , zlibDecompress
  , zlibDecompressWithHint
  , inflateRaw
  , adler32
  ) where

import Control.Exception (Exception, onException, throwIO, try)
import Control.Monad (forM_, when)
import Data.Array.Base (unsafeAt, unsafeWrite)
import Data.List (sortOn)
import Data.Array.ST (newArray, runSTUArray)
import Data.Array.Unboxed (UArray, accumArray, listArray, (!))
import Data.Bits (bit, complement, shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.Marshal.Alloc (free, mallocBytes, reallocBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (peekByteOff, pokeByteOff)
import System.IO.Unsafe (unsafePerformIO)

-- | Why a stream could not be decoded.
newtype InflateError = InflateError String
  deriving (Eq, Show)

instance Exception InflateError

-- | A decoded stream.
data Inflated = Inflated
  { inflatedBytes :: !ByteString
    -- ^ the decompressed data
  , inflatedConsumed :: !Int
    -- ^ how many input bytes the stream occupied (for zlib: header, deflate
    -- data and Adler-32 trailer)
  }
  deriving (Eq, Show)

failI :: String -> IO a
failI = throwIO . InflateError

-- | Decode a zlib stream (two-byte header, DEFLATE data, Adler-32).  Input
-- after the stream is ignored.  The header must be deflate, have a valid
-- check value and no preset dictionary; the Adler-32 must match.
zlibDecompress :: ByteString -> Either InflateError Inflated
zlibDecompress = zlibDecompressWithHint 0

-- | Like 'zlibDecompress', with a guess of the output size used to size the
-- initial buffer (a wrong guess only costs time).
zlibDecompressWithHint :: Int -> ByteString -> Either InflateError Inflated
zlibDecompressWithHint hint inp = unsafePerformIO . try $ do
  when (BS.length inp < 2) $ failI "zlib: truncated header"
  let cmf = fromIntegral (BS.index inp 0) :: Int
      flg = fromIntegral (BS.index inp 1) :: Int
  when (cmf .&. 15 /= 8) $ failI "zlib: not deflate"
  when ((cmf * 256 + flg) `mod` 31 /= 0) $ failI "zlib: bad header check"
  when (flg .&. 0x20 /= 0) $ failI "zlib: preset dictionary"
  (out, used) <- inflateCore (BS.drop 2 inp) hint
  let total = used + 2
  when (total + 4 > BS.length inp) $ failI "zlib: missing Adler-32"
  let stored = foldl (\a i -> a `shiftL` 8 .|. fromIntegral (BS.index inp (total + i))) 0 [0 .. 3] :: Word32
  when (stored /= adler32 out) $ failI "zlib: Adler-32 mismatch"
  pure (Inflated out (total + 4))

-- | Decode a raw DEFLATE stream.
inflateRaw :: ByteString -> Either InflateError Inflated
inflateRaw inp = unsafePerformIO . try $ do
  (out, used) <- inflateCore inp 0
  pure (Inflated out used)

-- | The Adler-32 checksum of a byte string.
adler32 :: ByteString -> Word32
adler32 bs = go 0 1 0
  where
    n = BS.length bs
    go !i !a !b
      | i >= n = (b `shiftL` 16) .|. a
      | otherwise =
          let end = min n (i + 5552)
              (a', b') = inner i end a b
           in go end (a' `mod` 65521) (b' `mod` 65521)
    inner !i !end !a !b
      | i >= end = (a, b)
      | otherwise =
          let a' = a + fromIntegral (BU.unsafeIndex bs i)
           in inner (i + 1) end a' (b + a')

------------------------------------------------------------------------------
-- Bit reader
--
-- State: next input position, bit buffer (LSB first), number of valid bits.
-- Past the end of the input the buffer is padded with zero bits; reading
-- them is detected by 'overrun'.

data BR = BR !Int !Word64 !Int

refill :: ByteString -> Int -> Word64 -> Int -> (Int -> Word64 -> Int -> IO r) -> IO r
refill inp = go
  where
    len = BS.length inp
    go !p !b !c k
      | c > 48 = k p b c
      | p < len = go (p + 1) (b .|. (fromIntegral (BU.unsafeIndex inp p) `shiftL` c)) (c + 8) k
      | otherwise = go (p + 1) b (c + 8) k
{-# INLINE refill #-}

-- | Fail if more bits were consumed than the input holds.
overrun :: ByteString -> Int -> Int -> IO ()
overrun inp p c = when (p * 8 - c > BS.length inp * 8) $ failI "unexpected end of input"
{-# INLINE overrun #-}

getBits :: ByteString -> Int -> BR -> IO (Int, BR)
getBits inp n (BR p0 b0 c0) = refill inp p0 b0 c0 $ \p b c -> do
  overrun inp p (c - n)
  pure (fromIntegral (b .&. (bit n - 1)), BR p (b `shiftR` n) (c - n))

------------------------------------------------------------------------------
-- Huffman tables

-- | A decoding table indexed by the next @maxBits@ input bits (LSB first);
-- an entry is @symbol * 16 + codeLength@, and 0 marks an unused code.
data HTable = HTable !Int !(UArray Int Word16)

buildTable :: [Int] -> Either String HTable
buildTable lens
  | maxLen == 0 = Right (HTable 1 (listArray (0, 1) [0, 0]))
  | oversubscribed = Left "oversubscribed Huffman code"
  | otherwise = Right (HTable maxLen table)
  where
    maxLen = maximum lens
    counts = accumArray (+) 0 (0, 15) [(l, 1) | l <- lens, l > 0] :: UArray Int Int
    oversubscribed = any (< 0) (drop 1 (scanl (\left l -> left * 2 - counts ! l) 1 [1 .. 15]))
    sorted = sortOn fst [(l, sym) | (sym, l) <- zip [0 :: Int ..] lens, l > 0]
    codes = assign 0 0 sorted
    assign :: Int -> Int -> [(Int, Int)] -> [(Int, Int, Int)]
    assign _ _ [] = []
    assign code prev ((l, sym) : rest) =
      let c = code `shiftL` (l - prev) in (sym, l, c) : assign (c + 1) l rest
    table = runSTUArray $ do
      tbl <- newArray (0, bit maxLen - 1) 0
      forM_ codes $ \(sym, l, c) -> do
        let entry = fromIntegral (sym * 16 + l) :: Word16
        forM_ [reverseBits c l, reverseBits c l + bit l .. bit maxLen - 1] $ \i ->
          unsafeWrite tbl i entry
      pure tbl

reverseBits :: Int -> Int -> Int
reverseBits c l = go c l 0
  where
    go _ 0 !acc = acc
    go x n !acc = go (x `shiftR` 1) (n - 1 :: Int) ((acc `shiftL` 1) .|. (x .&. 1))

fixedLit, fixedDist :: HTable
fixedLit = either error id (buildTable (replicate 144 8 ++ replicate 112 9 ++ replicate 24 7 ++ replicate 8 8))
fixedDist = either error id (buildTable (replicate 30 5))
{-# NOINLINE fixedLit #-}
{-# NOINLINE fixedDist #-}

lenBase, lenExtra, distBase, distExtra :: UArray Int Int
lenBase = listArray (0, 28) [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
lenExtra = listArray (0, 28) [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
distBase = listArray (0, 29) [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
distExtra = listArray (0, 29) [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

-- | Decode one symbol (only used for the dynamic block header).
decodeSym :: ByteString -> HTable -> BR -> IO (Int, BR)
decodeSym inp (HTable mb arr) (BR p0 b0 c0) = refill inp p0 b0 c0 $ \p b c -> do
  let e = fromIntegral (unsafeAt arr (fromIntegral (b .&. (bit mb - 1)))) :: Int
      l = e .&. 15
  when (l == 0) $ failI "invalid Huffman code"
  overrun inp p (c - l)
  pure (e `shiftR` 4, BR p (b `shiftR` l) (c - l))

-- | Read the code-length description of a dynamic block.
readDynamic :: ByteString -> BR -> IO (HTable, HTable, BR)
readDynamic inp br0 = do
  (hlit, br1) <- getBits inp 5 br0
  (hdist, br2) <- getBits inp 5 br1
  (hclen, br3) <- getBits inp 4 br2
  let nlit = hlit + 257
      ndist = hdist + 1
      ncl = hclen + 4
  when (nlit > 286 || ndist > 30) $ failI "too many length or distance codes"
  let readCl !i br acc
        | i >= ncl = pure (reverse acc, br)
        | otherwise = do
            (v, br') <- getBits inp 3 br
            readCl (i + 1) br' (v : acc)
  (clRaw, br4) <- readCl (0 :: Int) br3 []
  let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15] :: [Int]
      clLens = accumArray (\_ v -> v) 0 (0, 18) (zip order clRaw) :: UArray Int Int
  clTable <- either failI pure (buildTable [clLens ! i | i <- [0 .. 18]])
  let total = nlit + ndist
      readLens !n br acc
        | n >= total = pure (reverse acc, br)
        | otherwise = do
            (sym, br') <- decodeSym inp clTable br
            case sym of
              _ | sym < 16 -> readLens (n + 1) br' (sym : acc)
              16 -> do
                prev <- case acc of
                  (x : _) -> pure x
                  [] -> failI "repeat with no previous length"
                (r, br'') <- getBits inp 2 br'
                rep (3 + r) prev n br'' acc
              17 -> do
                (r, br'') <- getBits inp 3 br'
                rep (3 + r) 0 n br'' acc
              _ -> do
                (r, br'') <- getBits inp 7 br'
                rep (11 + r) 0 n br'' acc
      rep k v n br acc = do
        when (n + k > total) $ failI "code lengths overflow"
        readLens (n + k) br (replicate k v ++ acc)
  (lens, br5) <- readLens 0 br4 []
  let (litLens, distLens) = splitAt nlit lens
  when (litLens !! 256 == 0) $ failI "no end-of-block code"
  lt <- either failI pure (buildTable litLens)
  dt <- either failI pure (buildTable distLens)
  pure (lt, dt, br5)

------------------------------------------------------------------------------
-- The decoder proper

-- | State at a block boundary: bit reader, output length, buffer, capacity.
data St = St !BR !Int !(Ptr Word8) !Int

maxOutput :: Int
maxOutput = 1 `shiftL` 30

inflateCore :: ByteString -> Int -> IO (ByteString, Int)
inflateCore inp hint = do
  let cap0 = min maxOutput (max 0 hint) + 300
  ptr0 <- mallocBytes cap0
  ref <- newIORef ptr0
  St (BR p _ c) op ptr _ <-
    blocks ref (BR 0 0 0) 0 ptr0 cap0 `onException` (readIORef ref >>= free)
  let used = p - c `shiftR` 3
  (do overrun inp p (c .&. complement 7)
      ptr' <- reallocBytes ptr (max 1 op)
      out <- BU.unsafePackMallocCStringLen (castPtr ptr', op)
      pure (out, used))
    `onException` free ptr
  where
    inLen = BS.length inp

    blocks ref br op ptr cap = do
      (hdr, br1) <- getBits inp 3 br
      St br2 op2 ptr2 cap2 <- case hdr `shiftR` 1 of
        0 -> stored ref br1 op ptr cap
        1 -> codes ref fixedLit fixedDist br1 op ptr cap
        2 -> do
          (lt, dt, br') <- readDynamic inp br1
          codes ref lt dt br' op ptr cap
        _ -> failI "invalid block type"
      if hdr .&. 1 == 1
        then pure (St br2 op2 ptr2 cap2)
        else blocks ref br2 op2 ptr2 cap2

    grow ref ptr cap need = do
      when (need > maxOutput) $ failI "output too large"
      let cap' = min maxOutput (max need (cap * 2))
      ptr' <- reallocBytes ptr cap'
      writeIORef ref ptr'
      pure (ptr', cap')

    stored ref (BR p _ c) op ptr cap = do
      let q = p - c `shiftR` 3
      when (q + 4 > inLen) $ failI "truncated stored block"
      let byte i = fromIntegral (BU.unsafeIndex inp (q + i)) :: Int
          n = byte 0 .|. (byte 1 `shiftL` 8)
          nn = byte 2 .|. (byte 3 `shiftL` 8)
      when (n /= complement nn .&. 0xffff) $ failI "stored block length mismatch"
      when (q + 4 + n > inLen) $ failI "truncated stored block"
      (ptr', cap') <- if op + n + 300 > cap then grow ref ptr cap (op + n + 300) else pure (ptr, cap)
      BU.unsafeUseAsCString inp $ \src ->
        copyBytes (ptr' `plusPtr` op) (castPtr src `plusPtr` (q + 4)) n
      pure (St (BR (q + 4 + n) 0 0) (op + n) ptr' cap')

    codes ref (HTable lb larr) (HTable db darr) (BR p0 b0 c0) op0 ptr0 cap0 =
      loop p0 b0 c0 op0 ptr0 cap0
      where
        lmask = bit lb - 1 :: Word64
        dmask = bit db - 1 :: Word64
        loop !p1 !b1 !c1 !op !ptr !cap
          | op + 258 > cap = do
              (ptr', cap') <- grow ref ptr cap (op + 258)
              loop p1 b1 c1 op ptr' cap'
          | otherwise = refill inp p1 b1 c1 $ \p b c -> do
              overrun inp p c
              let e = fromIntegral (unsafeAt larr (fromIntegral (b .&. lmask))) :: Int
                  l = e .&. 15
                  sym = e `shiftR` 4
              when (l == 0) $ failI "invalid literal/length code"
              let bA = b `shiftR` l
                  cA = c - l
              if sym < 256
                then do
                  pokeByteOff ptr op (fromIntegral sym :: Word8)
                  loop p bA cA (op + 1) ptr cap
                else
                  if sym == 256
                    then pure (St (BR p bA cA) op ptr cap)
                    else do
                      let li = sym - 257
                      when (li >= 29) $ failI "invalid length symbol"
                      let eb = unsafeAt lenExtra li
                          len = unsafeAt lenBase li + fromIntegral (bA .&. (bit eb - 1))
                          bB = bA `shiftR` eb
                          cB = cA - eb
                          de = fromIntegral (unsafeAt darr (fromIntegral (bB .&. dmask))) :: Int
                          dl = de .&. 15
                          dsym = de `shiftR` 4
                      when (dl == 0 || dsym >= 30) $ failI "invalid distance code"
                      let bC = bB `shiftR` dl
                          cC = cB - dl
                          deb = unsafeAt distExtra dsym
                          dist = unsafeAt distBase dsym + fromIntegral (bC .&. (bit deb - 1))
                      when (dist > op) $ failI "distance too far back"
                      copyMatch ptr op dist len
                      loop p (bC `shiftR` deb) (cC - deb) (op + len) ptr cap

copyMatch :: Ptr Word8 -> Int -> Int -> Int -> IO ()
copyMatch ptr op dist len = go 0
  where
    src = op - dist
    go !i
      | i >= len = pure ()
      | otherwise = do
          x <- peekByteOff ptr (src + i) :: IO Word8
          pokeByteOff ptr (op + i) x
          go (i + 1)
