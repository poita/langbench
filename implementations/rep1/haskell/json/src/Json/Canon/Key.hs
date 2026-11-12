-- |
-- Module      : Json.Canon.Key
-- Description : Object-key ordering by UTF-16 code units.
module Json.Canon.Key
  ( compareKeys
  ) where

import Data.Text (Text)
import Data.Text.Array (unsafeIndex)
import Data.Text.Internal (Text (..))

-- | Compare two strings by their UTF-16 code unit sequences (unsigned 16-bit
-- units, a proper prefix sorts first).
--
-- 'Text' is stored as UTF-8, whose byte order is code point order. UTF-16
-- order differs only in that supplementary characters (U+10000 and above,
-- lead byte @0xF0@–@0xF4@) sort /before/ U+E000–U+FFFF (lead byte @0xEE@ or
-- @0xEF@). So: compare bytes, and at the first differing byte, which is
-- necessarily a lead byte of both strings, invert the result if exactly one
-- is such a supplementary lead byte and the other a @0xEE@/@0xEF@ one.
-- Runs in time proportional to the common prefix length.
compareKeys :: Text -> Text -> Ordering
compareKeys (Text a ao al) (Text b bo bl) = go 0
  where
    n = min al bl
    go i
      | i == n = compare al bl
      | x == y = go (i + 1)
      | high x && supp y || supp x && high y = compare y x
      | otherwise = compare x y
      where
        x = unsafeIndex a (ao + i)
        y = unsafeIndex b (bo + i)
    high w = w == 0xEE || w == 0xEF
    supp w = w >= 0xF0
