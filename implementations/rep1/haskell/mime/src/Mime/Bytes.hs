-- | Byte-string utilities: line handling and the Adler-32 checksum.
module Mime.Bytes
  ( normalizeNewlines
  , nextLine
  , dropOneTrailingLF
  , adler32
  , adler32Hex
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Bits (shiftL, (.|.))
import Data.Word (Word32)
import Numeric (showHex)

-- | Turn every CRLF into a single LF; nothing else changes.
normalizeNewlines :: B.ByteString -> B.ByteString
normalizeNewlines bs
  | B.notElem 13 bs = bs
  | otherwise = B.intercalate (BC.singleton '\n') (fixAll (B.split 10 bs))
  where
    fixAll [] = []
    fixAll [l] = [l]
    fixAll (l : ls) = fix l : fixAll ls
    fix l = if not (B.null l) && B.last l == 13 then B.init l else l

-- | Split off the first line (without its terminator).  The remainder starts
-- after the LF.  A CR before the LF is removed from the line.
nextLine :: B.ByteString -> (B.ByteString, B.ByteString)
nextLine bs = case B.elemIndex 10 bs of
  Nothing -> (bs, B.empty)
  Just i ->
    let l = B.take i bs
        l' = if i > 0 && B.index l (i - 1) == 13 then B.take (i - 1) l else l
     in (l', B.drop (i + 1) bs)

-- | Drop a single trailing LF if present.
dropOneTrailingLF :: B.ByteString -> B.ByteString
dropOneTrailingLF bs
  | not (B.null bs) && B.last bs == 10 = B.init bs
  | otherwise = bs

-- | The Adler-32 checksum.
adler32 :: B.ByteString -> Word32
adler32 bs = (b `shiftL` 16) .|. a
  where
    (a, b) = B.foldl' step (1, 0) bs
    step (!x, !y) w =
      let x' = (x + fromIntegral w) `mod` 65521
       in (x', (y + x') `mod` 65521)

-- | Adler-32 as exactly eight lower-case hexadecimal digits.
adler32Hex :: B.ByteString -> String
adler32Hex bs = let h = showHex (adler32 bs) "" in replicate (8 - length h) '0' ++ h

