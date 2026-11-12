-- |
-- Module      : Git.Quote
-- Description : Git's default path quoting.
module Git.Quote
  ( quotePath
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word8)

-- | Quote a path the way git prints it by default: unchanged when every byte
-- is printable ASCII and neither @"@ nor @\\@; otherwise wrapped in double
-- quotes with C escapes and three-digit octal for other bytes.
quotePath :: ByteString -> ByteString
quotePath name
  | BS.all plain name = name
  | otherwise = BS.concat [BC.pack "\"", BS.concatMap esc name, BC.pack "\""]
  where
    plain c = c >= 0x20 && c <= 0x7e && c /= 0x22 && c /= 0x5c
    esc :: Word8 -> ByteString
    esc c = case c of
      7 -> BC.pack "\\a"
      8 -> BC.pack "\\b"
      9 -> BC.pack "\\t"
      10 -> BC.pack "\\n"
      11 -> BC.pack "\\v"
      12 -> BC.pack "\\f"
      13 -> BC.pack "\\r"
      0x22 -> BC.pack "\\\""
      0x5c -> BC.pack "\\\\"
      _
        | c < 0x20 || c >= 0x7f -> BS.pack [0x5c, 48 + c `div` 64, 48 + (c `div` 8) `mod` 8, 48 + c `mod` 8]
        | otherwise -> BS.singleton c
