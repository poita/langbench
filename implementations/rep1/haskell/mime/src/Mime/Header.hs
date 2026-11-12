-- | Header block parsing: line scanning, unfolding and field lookup.
module Mime.Header
  ( Field (..)
  , parseHeaders
  , fieldNameKey
  , lookupField
  , lookupFields
  , fieldValue
  ) where

import qualified Data.ByteString as B

import Mime.Bytes (nextLine)
import Mime.Charset (decodeUtf8)
import Mime.EncodedWord (decodeUnstructured)
import Mime.Lexical

-- | One (unfolded) header field.
data Field = Field
  { fieldName :: String
  -- ^ the name exactly as written (text before the first colon)
  , fieldRaw :: String
  -- ^ the unfolded raw value (text after the first colon)
  }
  deriving (Eq, Show)

-- | The lower-cased, stripped field name used for comparisons.
fieldNameKey :: Field -> String
fieldNameKey = lowerStr . stripBlanks . fieldName

-- | Split a message (with LF line endings) into its fields and its body.
parseHeaders :: B.ByteString -> ([Field], B.ByteString)
parseHeaders = go Nothing []
  where
    finish cur acc = reverse (maybe acc (: acc) (fmap mk cur))
    mk ls = let t = decodeUtf8 (B.concat (reverse ls))
                (n, v) = break (== ':') t
             in Field n (drop 1 v)
    go cur acc rest
      | B.null rest = (finish cur acc, B.empty)
      | B.null line = (finish cur acc, rest')
      | isFold, Just ls <- cur = go (Just (line : ls)) acc rest'
      | isFieldLine line = go (Just [line]) (maybe acc (\c -> mk c : acc) cur) rest'
      | otherwise = (finish cur acc, rest)
      where
        (line, rest') = nextLine rest
        isFold = B.head line == 32 || B.head line == 9
    isFieldLine l = case B.elemIndex 58 l of
      Just i | i > 0 -> B.all (\w -> w >= 0x21 && w <= 0x7E) (B.take i l)
      _ -> False

-- | The first field with the given (lower-case) name.
lookupField :: String -> [Field] -> Maybe Field
lookupField k fs = case lookupFields k fs of
  f : _ -> Just f
  [] -> Nothing

-- | All fields with the given (lower-case) name, in order.
lookupFields :: String -> [Field] -> [Field]
lookupFields k = filter ((== k) . fieldNameKey)

-- | The value of a field as shown in the dump: collapsed for a fixed set of
-- structured headers, RFC 2047-decoded for all others.
fieldValue :: Field -> String
fieldValue f
  | fieldNameKey f `elem` collapsed = collapse (fieldRaw f)
  | otherwise = decodeUnstructured (fieldRaw f)
  where
    collapsed =
      [ "content-disposition", "content-id", "content-transfer-encoding"
      , "content-type", "date", "in-reply-to", "message-id", "mime-version"
      , "received", "references", "return-path"
      ]
