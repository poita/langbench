{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Codec.Compression.Inflate.Decoder
-- Description : The DEFLATE block decoder (internal).
--
-- The decoder works in 'IO' over a growable, manually managed output buffer
-- and reports malformations by throwing 'InflateError'; "Codec.Compression.Inflate"
-- wraps it in a pure interface.
module Codec.Compression.Inflate.Decoder
  ( decode
  ) where

import Control.Exception (throwIO)
import Control.Monad (when)
import Data.Array.Base (unsafeAt, unsafeFreeze, unsafeRead, unsafeWrite)
import Data.Array.IO (IOUArray, newArray)
import Data.Array.Unboxed (UArray)
import Data.Bits (unsafeShiftL, unsafeShiftR, xor, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word64, Word8)
import Foreign.ForeignPtr (ForeignPtr, touchForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (peekByteOff, pokeByteOff)

import Codec.Compression.Inflate.Huffman
import Codec.Compression.Inflate.Tables
import Codec.Compression.Inflate.Types

-- | Bit reader state: next input byte index, bit buffer (next stream bit in
-- the least significant position) and number of valid bits in the buffer.
data BR = BR !Int !Word64 !Int

-- | Output buffer: storage, capacity and number of bytes written.
data Out = Out !(ForeignPtr Word8) !Int !Int

-- | Decode a complete raw DEFLATE stream.
decode :: B.ByteString -> IO B.ByteString
decode inp = do
  let cap0 = max 4096 (4 * B.length inp)
  fp <- BI.mallocByteString cap0
  (BR pos _ cnt, Out fp' _ len) <- blocks inp (BR 0 0 0) (Out fp cap0 0)
  -- Whole bytes still sitting in the bit buffer were never consumed.
  when (pos - cnt `unsafeShiftR` 3 < B.length inp) $ throwIO TrailingData
  return (BI.fromForeignPtr fp' 0 len)

-- | Decode blocks until (and including) the one flagged final.
blocks :: B.ByteString -> BR -> Out -> IO (BR, Out)
blocks inp br0 out0 = do
  (hdr, br1) <- getBits inp 3 br0
  let final = hdr .&. 1 == 1
  (br2, out1) <- case hdr `unsafeShiftR` 1 of
    0 -> stored inp br1 out0
    1 -> codes inp fixedLit fixedDist br1 out0
    2 -> do
      (lit, dist, br') <- readDynamic inp br1
      codes inp lit dist br' out0
    _ -> throwIO InvalidBlockType
  if final then return (br2, out1) else blocks inp br2 out1

fixedLit, fixedDist :: Table
fixedLit = mustBuild 10 fixedLitLenLengths 288
fixedDist = mustBuild 8 fixedDistLengths 32
{-# NOINLINE fixedLit #-}
{-# NOINLINE fixedDist #-}

mustBuild :: Int -> UArray Int Word8 -> Int -> Table
mustBuild root lens n = case buildTable root lens 0 n of
  Just t -> t
  Nothing -> error "Inflate: fixed code is over-subscribed"

------------------------------------------------------------------------------
-- Bit reading (slow path, used for headers)

refillBR :: B.ByteString -> BR -> BR
refillBR inp (BR p0 b0 c0) = go p0 b0 c0
  where
    len = B.length inp
    go !p !b !c
      | c <= 56 && p < len =
          go (p + 1) (b .|. (fromIntegral (BU.unsafeIndex inp p) `unsafeShiftL` c)) (c + 8)
      | otherwise = BR p b c

getBits :: B.ByteString -> Int -> BR -> IO (Int, BR)
getBits inp n br = do
  let BR p b c = refillBR inp br
  when (c < n) $ throwIO UnexpectedEnd
  return (fromIntegral (b .&. ((1 `unsafeShiftL` n) - 1)), BR p (b `unsafeShiftR` n) (c - n))

-- | Decode one symbol (slow path).
getSymbol :: B.ByteString -> Table -> BR -> IO (Int, BR)
getSymbol inp tbl br = do
  let BR p b c = refillBR inp br
  decodeSym tbl b c $ \sym b' c' -> return (sym, BR p b' c')

------------------------------------------------------------------------------
-- Hot-path primitives (continuation-passing so they inline without allocation)

-- | Decode a symbol from the bit buffer.
decodeSym :: Table -> Word64 -> Int -> (Int -> Word64 -> Int -> IO r) -> IO r
decodeSym tbl b c k
  | e == 0 = throwIO (if c >= tableMaxLen tbl then InvalidHuffmanCode else UnexpectedEnd)
  | l > c = throwIO UnexpectedEnd
  | otherwise = k (entrySymbol e) (b `unsafeShiftR` l) (c - l)
  where
    e = lookupEntry tbl b
    l = entryLength e
{-# INLINE decodeSym #-}

-- | Take @n@ bits (LSB first) from the bit buffer.
takeBits :: Int -> Word64 -> Int -> (Int -> Word64 -> Int -> IO r) -> IO r
takeBits n b c k
  | n > c = throwIO UnexpectedEnd
  | otherwise = k (fromIntegral (b .&. ((1 `unsafeShiftL` n) - 1))) (b `unsafeShiftR` n) (c - n)
{-# INLINE takeBits #-}

------------------------------------------------------------------------------
-- Output buffer

-- | Make sure at least @need@ more bytes fit.
reserve :: Int -> ForeignPtr Word8 -> Int -> Int -> IO (ForeignPtr Word8, Int)
reserve need fp cap len
  | len + need <= cap = return (fp, cap)
  | otherwise = do
      let cap' = grow cap
          grow c = if len + need <= c then c else grow (c * 2)
      fp' <- BI.mallocByteString cap'
      copyBytes (unsafeForeignPtrToPtr fp') (unsafeForeignPtrToPtr fp) len
      touchForeignPtr fp
      touchForeignPtr fp'
      return (fp', cap')

------------------------------------------------------------------------------
-- Stored blocks

stored :: B.ByteString -> BR -> Out -> IO (BR, Out)
stored inp (BR pos _ c) (Out fp cap len) = do
  -- Drop the bits up to the next byte boundary, then go back to byte addressing.
  let whole = c `unsafeShiftR` 3
      start = pos - whole
      n = B.length inp
  when (start + 4 > n) $ throwIO UnexpectedEnd
  let byte i = fromIntegral (BU.unsafeIndex inp (start + i)) :: Int
      blen = byte 0 .|. (byte 1 `unsafeShiftL` 8)
      nlen = byte 2 .|. (byte 3 `unsafeShiftL` 8)
  when (blen `xor` nlen /= 0xFFFF) $ throwIO StoredLengthMismatch
  let dataStart = start + 4
  when (dataStart + blen > n) $ throwIO UnexpectedEnd
  (fp', cap') <- reserve blen fp cap len
  BU.unsafeUseAsCString inp $ \src ->
    copyBytes (unsafeForeignPtrToPtr fp' `plusPtr` len) (src `plusPtr` dataStart) blen
  touchForeignPtr fp'
  return (BR (dataStart + blen) 0 0, Out fp' cap' (len + blen))

------------------------------------------------------------------------------
-- Dynamic block headers

readDynamic :: B.ByteString -> BR -> IO (Table, Table, BR)
readDynamic inp br0 = do
  (hlit, br1) <- getBits inp 5 br0
  (hdist, br2) <- getBits inp 5 br1
  (hclen, br3) <- getBits inp 4 br2
  when (hlit > 29 || hdist > 29) $ throwIO TooManyCodes
  let nlit = hlit + 257
      ndist = hdist + 1
      total = nlit + ndist
  clLens <- newArray (0, 18) 0 :: IO (IOUArray Int Word8)
  let readCl !i !br
        | i >= hclen + 4 = return br
        | otherwise = do
            (v, br') <- getBits inp 3 br
            unsafeWrite clLens (codeLengthOrder `unsafeAt` i) (fromIntegral v)
            readCl (i + 1) br'
  br4 <- readCl 0 br3
  clFrozen <- unsafeFreeze clLens :: IO (UArray Int Word8)
  clTable <- case buildTable 7 clFrozen 0 19 of
    Just t | tableComplete t -> return t
    _ -> throwIO InvalidCodeLengthCode
  lens <- newArray (0, total - 1) 0 :: IO (IOUArray Int Word8)
  let fillRun !i !cnt !v
        | cnt == 0 = return ()
        | otherwise = unsafeWrite lens i v >> fillRun (i + 1) (cnt - 1 :: Int) v
      readLens !i !br
        | i >= total = return br
        | otherwise = do
            (sym, br') <- getSymbol inp clTable br
            if sym < 16
              then unsafeWrite lens i (fromIntegral sym) >> readLens (i + 1) br'
              else do
                (cnt, v, br'') <- case sym of
                  16 -> do
                    when (i == 0) $ throwIO RepeatWithoutPrevious
                    prev <- unsafeRead lens (i - 1)
                    (e, b) <- getBits inp 2 br'
                    return (3 + e, prev, b)
                  17 -> do
                    (e, b) <- getBits inp 3 br'
                    return (3 + e, 0, b)
                  _ -> do
                    (e, b) <- getBits inp 7 br'
                    return (11 + e, 0, b)
                when (i + cnt > total) $ throwIO RepeatOverflow
                fillRun i cnt v
                readLens (i + cnt) br''
  br5 <- readLens 0 br4
  allLens <- unsafeFreeze lens :: IO (UArray Int Word8)
  when (allLens `unsafeAt` 256 == 0) $ throwIO MissingEndOfBlock
  lit <- case buildTable 10 allLens 0 nlit of
    Just t | tableComplete t || singleBit t -> return t
    _ -> throwIO InvalidLiteralLengthCode
  dist <- case buildTable 8 allLens nlit ndist of
    Just t | tableComplete t || tableUsed t == 0 || singleBit t -> return t
    _ -> throwIO InvalidDistanceCode
  return (lit, dist, br5)
  where
    -- Exactly one code, of length one.
    singleBit t = tableUsed t == 1 && tableMaxLen t == 1

------------------------------------------------------------------------------
-- Compressed blocks

-- | Decode literal/length and distance symbols until end-of-block.
codes :: B.ByteString -> Table -> Table -> BR -> Out -> IO (BR, Out)
codes inp lit dist (BR pos0 bb0 bc0) (Out fp0 cap0 len0) = go pos0 bb0 bc0 fp0 cap0 len0
  where
    n = B.length inp
    noDist = tableUsed dist == 0

    go !pos !bb !bc !fp !cap !op
      | op + 258 > cap = do
          (fp', cap') <- reserve 258 fp cap op
          go pos bb bc fp' cap' op
      | otherwise = fill pos bb bc
      where
        fill !p !b !c
          | c <= 56 && p < n =
              fill (p + 1) (b .|. (fromIntegral (BU.unsafeIndex inp p) `unsafeShiftL` c)) (c + 8)
          | otherwise = body p b c

        out = unsafeForeignPtrToPtr fp

        body !p !b !c = decodeSym lit b c $ \sym b1 c1 ->
          if sym < 256
            then do
              pokeByteOff out op (fromIntegral sym :: Word8)
              go p b1 c1 fp cap (op + 1)
            else if sym == 256
              then do
                touchForeignPtr fp
                return (BR p b1 c1, Out fp cap op)
              else match p b1 c1 sym

        match !p !b !c !sym = do
          when (sym > 285) $ throwIO InvalidLengthSymbol
          when noDist $ throwIO NoDistanceCodes
          let li = sym - 257
          takeBits (lengthExtra `unsafeAt` li) b c $ \lx b1 c1 ->
            decodeSym dist b1 c1 $ \dsym b2 c2 -> do
              when (dsym > 29) $ throwIO InvalidDistanceSymbol
              takeBits (distExtra `unsafeAt` dsym) b2 c2 $ \dx b3 c3 -> do
                let l = lengthBase `unsafeAt` li + lx
                    d = distBase `unsafeAt` dsym + dx
                when (d > op) $ throwIO DistanceTooFar
                copyMatch out op d l
                go p b3 c3 fp cap (op + l)

-- | Copy @l@ bytes from @d@ bytes back, byte by byte when the regions overlap.
copyMatch :: Ptr Word8 -> Int -> Int -> Int -> IO ()
copyMatch out op d l
  | d >= l = copyBytes (out `plusPtr` op) (out `plusPtr` (op - d)) l
  | otherwise = loop 0
  where
    loop !i
      | i >= l = return ()
      | otherwise = do
          x <- peekByteOff out (op - d + i) :: IO Word8
          pokeByteOff out (op + i) x
          loop (i + 1)
{-# INLINE copyMatch #-}
