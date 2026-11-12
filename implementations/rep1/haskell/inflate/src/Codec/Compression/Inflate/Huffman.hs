-- |
-- Module      : Codec.Compression.Inflate.Huffman
-- Description : Canonical Huffman code construction and table-driven lookup.
--
-- A code is described by a code length per symbol (0 = unused). 'buildTable'
-- turns that into a two-level lookup table: a /root/ table indexed by the next
-- @root@ stream bits, whose entries are either a finished symbol or a link to
-- a second-level table for the codes longer than @root@ bits. Building costs
-- O(symbols + 2^root); decoding a symbol costs one or two array reads.
--
-- DEFLATE packs Huffman codes most-significant-bit first into a stream that is
-- consumed least-significant-bit first, so tables are indexed by the
-- bit-/reversed/ code.
module Codec.Compression.Inflate.Huffman
  ( Table (..)
  , buildTable
  , lookupEntry
  , entryLength
  , entrySymbol
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeAt, unsafeFreeze, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray)
import Data.Array.Unboxed (UArray)
import Data.Bits (complement, shiftL, shiftR, unsafeShiftL, unsafeShiftR, (.&.), (.|.))
import Data.Word (Word16, Word32, Word64, Word8)

-- | A decoding table.
--
-- Entry layout (a 'Word32'):
--
-- * @0@: no code has this bit pattern;
-- * bit 31 clear: a symbol; bits 0-3 hold the code length (1-15) and bits 4+
--   the symbol;
-- * bit 31 set: a link; bits 0-3 hold the width of the second-level table and
--   bits 4-30 its offset within 'tableEntries'.
data Table = Table
  { tableRoot     :: !Int
    -- ^ Number of bits indexing the root table.
  , tableMaxLen   :: !Int
    -- ^ Longest code length in use (0 if there are no codes).
  , tableUsed     :: !Int
    -- ^ Number of symbols with a nonzero length.
  , tableComplete :: !Bool
    -- ^ Whether the Kraft sum is exactly 1.
  , tableEntries  :: !(UArray Int Word32)
  }

linkBit :: Word32
linkBit = 0x80000000

-- | @buildTable root lengths offset count@ builds the table for the code
-- whose lengths are @lengths[offset .. offset + count - 1]@ (each 0..15).
-- Returns 'Nothing' if the lengths are over-subscribed. Incomplete codes are
-- accepted; the unused bit patterns decode to entry 0. The caller decides
-- whether incompleteness is acceptable (see 'tableComplete').
buildTable :: Int -> UArray Int Word8 -> Int -> Int -> Maybe Table
buildTable root lens off n = runST $ do
  counts <- newArray (0, 15) 0 :: ST s (STUArray s Int Int)
  forM_ [0 .. n - 1] $ \i -> do
    let l = fromIntegral (lens `unsafeAt` (off + i))
    c <- unsafeRead counts l
    unsafeWrite counts l (c + 1)
  -- Kraft sum, scaled by 2^15, computed as the number of free code slots.
  let kraft !l !left !maxL
        | l > 15 = return (left, maxL)
        | otherwise = do
            c <- unsafeRead counts l
            kraft (l + 1) (left * 2 - c) (if c > 0 then l else maxL)
  (left, maxLen) <- kraft 1 (1 :: Int) 0
  -- 'left' went negative at some point iff over-subscribed; once negative it
  -- only gets more negative, so checking the final value suffices.
  if left < 0
    then return Nothing
    else do
      used <- do
        z <- unsafeRead counts 0
        return (n - z)
      nextCode <- newArray (0, 15) 0 :: ST s (STUArray s Int Int)
      let nc !l !code
            | l > 15 = return ()
            | otherwise = do
                prev <- if l == 1 then return 0 else unsafeRead counts (l - 1)
                let code' = (code + prev) `shiftL` 1
                unsafeWrite nextCode l code'
                nc (l + 1) code'
      nc 1 0
      -- Reversed code of every symbol.
      rcodes <- newArray (0, max 0 (n - 1)) 0 :: ST s (STUArray s Int Word16)
      forM_ [0 .. n - 1] $ \s -> do
        let l = fromIntegral (lens `unsafeAt` (off + s))
        when (l /= 0) $ do
          c <- unsafeRead nextCode l
          unsafeWrite nextCode l (c + 1)
          unsafeWrite rcodes s (reverseBits l (fromIntegral c))
      let rootSize = 1 `shiftL` root :: Int
          rootMask = rootSize - 1
      -- Width of the second-level table needed under each root prefix.
      subW <- newArray (0, rootSize - 1) 0 :: ST s (STUArray s Int Word8)
      when (maxLen > root) $
        forM_ [0 .. n - 1] $ \s -> do
          let l = fromIntegral (lens `unsafeAt` (off + s))
          when (l > root) $ do
            rc <- unsafeRead rcodes s
            let p = fromIntegral rc .&. rootMask
            w <- unsafeRead subW p
            when (fromIntegral (l - root) > w) $ unsafeWrite subW p (fromIntegral (l - root))
      -- Lay out the second-level tables after the root table.
      subOff <- newArray (0, rootSize - 1) 0 :: ST s (STUArray s Int Int)
      let layout !p !total
            | p >= rootSize = return total
            | otherwise = do
                w <- unsafeRead subW p
                if w == 0
                  then layout (p + 1) total
                  else do
                    unsafeWrite subOff p total
                    layout (p + 1) (total + (1 `shiftL` fromIntegral w))
      total <- if maxLen > root then layout 0 rootSize else return rootSize
      entries <- newArray (0, total - 1) 0 :: ST s (STUArray s Int Word32)
      when (maxLen > root) $
        forM_ [0 .. rootSize - 1] $ \p -> do
          w <- unsafeRead subW p
          when (w /= 0) $ do
            o <- unsafeRead subOff p
            unsafeWrite entries p (linkBit .|. (fromIntegral o `shiftL` 4) .|. fromIntegral w)
      forM_ [0 .. n - 1] $ \s -> do
        let l = fromIntegral (lens `unsafeAt` (off + s)) :: Int
        when (l /= 0) $ do
          rc <- (fromIntegral :: Word16 -> Int) <$> unsafeRead rcodes s
          let leaf = (fromIntegral s `shiftL` 4) .|. fromIntegral l :: Word32
          if l <= root
            then
              let fill !i
                    | i >= rootSize = return ()
                    | otherwise = unsafeWrite entries i leaf >> fill (i + (1 `shiftL` l))
              in fill rc
            else do
              let p = rc .&. rootMask
              w <- (fromIntegral :: Word8 -> Int) <$> unsafeRead subW p
              o <- unsafeRead subOff p
              let size = 1 `shiftL` w :: Int
                  step = 1 `shiftL` (l - root) :: Int
                  fill !i
                    | i >= size = return ()
                    | otherwise = unsafeWrite entries (o + i) leaf >> fill (i + step)
              fill (rc `shiftR` root)
      frozen <- unsafeFreeze entries
      return $ Just Table
        { tableRoot = root
        , tableMaxLen = maxLen
        , tableUsed = used
        , tableComplete = left == 0
        , tableEntries = frozen
        }

-- | Reverse the low @l@ bits of a code.
reverseBits :: Int -> Word16 -> Word16
reverseBits l x0 = x4 `shiftR` (16 - l)
  where
    x1 = ((x0 .&. 0x5555) `shiftL` 1) .|. ((x0 `shiftR` 1) .&. 0x5555)
    x2 = ((x1 .&. 0x3333) `shiftL` 2) .|. ((x1 `shiftR` 2) .&. 0x3333)
    x3 = ((x2 .&. 0x0f0f) `shiftL` 4) .|. ((x2 `shiftR` 4) .&. 0x0f0f)
    x4 = (x3 `shiftL` 8) .|. (x3 `shiftR` 8)

-- | Look up the table entry for the next bits of the stream (least
-- significant bit = next bit). The result is 0 if no code matches, otherwise
-- a symbol entry; use 'entryLength' and 'entrySymbol' to take it apart.
lookupEntry :: Table -> Word64 -> Word32
lookupEntry (Table root _ _ _ arr) bits =
  let e = arr `unsafeAt` (fromIntegral bits .&. ((1 `unsafeShiftL` root) - 1))
  in if e .&. linkBit == 0
       then e
       else
         let w = fromIntegral (e .&. 15) :: Int
             o = fromIntegral ((e .&. complement linkBit) `unsafeShiftR` 4) :: Int
             i = fromIntegral (bits `unsafeShiftR` root) .&. ((1 `unsafeShiftL` w) - 1)
         in arr `unsafeAt` (o + i)
{-# INLINE lookupEntry #-}

-- | Code length (bits to consume) of a symbol entry.
entryLength :: Word32 -> Int
entryLength e = fromIntegral (e .&. 15)
{-# INLINE entryLength #-}

-- | Symbol of a symbol entry.
entrySymbol :: Word32 -> Int
entrySymbol e = fromIntegral (e `unsafeShiftR` 4)
{-# INLINE entrySymbol #-}
