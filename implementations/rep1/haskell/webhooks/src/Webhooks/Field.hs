-- | Syntax of the individual protocol fields (ids, integers, names) shared by
-- the signature scheme, the simulator and the command interpreter.
module Webhooks.Field
  ( splitFields
  , isBlank
  , parseInt
  , parseId
  , parseReceivedText
  , parseName
  , maxTimestamp
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word8)

-- | Split a line into fields on single spaces. Adjacent, leading and
-- trailing spaces yield empty fields.
splitFields :: ByteString -> [ByteString]
splitFields = BS.split 32

-- | An empty line, or one consisting only of spaces.
isBlank :: ByteString -> Bool
isBlank = BS.all (== 32)

-- | Largest absolute value of a timestamp, 10^15.
maxTimestamp :: Int
maxTimestamp = 1000000000000000

-- | A canonical decimal integer: @0@, or an optional @-@ followed by a digit
-- @1@-@9@ and further digits, with absolute value at most 10^15.
-- @+5@, @007@, @-0@, @1.0@ and @1e3@ are not canonical.
parseInt :: ByteString -> Maybe Int
parseInt s = case BS.uncons s of
  Just (48, rest) | BS.null rest -> Just 0
  Just (45, rest) -> negate <$> positive rest
  _ -> positive s
  where
    positive d = case BS.uncons d of
      Just (c, _)
        | c >= 49 && c <= 57 && BS.length d <= 16 && BS.all isDigit d ->
            let v = BS.foldl' (\acc x -> acc * 10 + fromIntegral (x - 48)) 0 d
             in if v <= maxTimestamp then Just v else Nothing
      _ -> Nothing

isDigit :: Word8 -> Bool
isDigit c = c >= 48 && c <= 57

printable :: Word8 -> Bool
printable c = c >= 0x21 && c <= 0x7e

-- | An @\<id\>@: 1 to 256 printable ASCII characters, no space.
parseId :: ByteString -> Maybe ByteString
parseId = bounded 256 printable

-- | A received (not necessarily canonical) timestamp field: 1 to 64
-- printable ASCII characters.
parseReceivedText :: ByteString -> Maybe ByteString
parseReceivedText = bounded 64 printable

-- | An endpoint id, event id or event type: 1 to 64 characters from
-- @[A-Za-z0-9_.-]@.
parseName :: ByteString -> Maybe ByteString
parseName = bounded 64 nameChar
  where
    nameChar c =
      (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || isDigit c || c == 95 || c == 46 || c == 45

bounded :: Int -> (Word8 -> Bool) -> ByteString -> Maybe ByteString
bounded limit ok s
  | n >= 1 && n <= limit && BS.all ok s = Just s
  | otherwise = Nothing
  where
    n = BS.length s
