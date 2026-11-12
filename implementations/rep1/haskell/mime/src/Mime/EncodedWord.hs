-- | RFC 2047 encoded words and the two text decoders built on them.
module Mime.EncodedWord
  ( matchEncodedWord
  , decodeUnstructured
  , decodeDisplay
  ) where

import qualified Data.ByteString as B
import Data.Word (Word8)

import Mime.Charset (decode, encodeUtf8)
import Mime.Lexical
import Mime.Transfer (decodeBase64)
import Data.Char (isAscii, ord)
import Data.Bits (shiftL, (.|.))

-- | If an encoded word starts at the head of the string, return its decoded
-- text, its length in characters and the remaining input.
matchEncodedWord :: String -> Maybe (String, Int, String)
matchEncodedWord ('=' : '?' : r0) =
  case break (== '?') r0 of
    (cs, '?' : k : '?' : r2)
      | not (null cs), not (any isBlank cs), k `elem` "QqBb" ->
          case break (== '?') r2 of
            (txt, '?' : '=' : r4)
              | not (any isBlank txt) ->
                  Just (decodeWord cs k txt, 2 + length cs + 3 + length txt + 2, r4)
            _ -> Nothing
    _ -> Nothing
matchEncodedWord _ = Nothing

decodeWord :: String -> Char -> String -> String
decodeWord cs k txt = decode charset bytes
  where
    cs' = lowerAscii (stripBlanks (takeWhile (/= '*') cs))
    charset = if null cs' then "us-ascii" else cs'
    bytes
      | k == 'Q' || k == 'q' = B.pack (qBytes txt)
      | otherwise = decodeBase64 (B.pack [fromIntegral (ord c) | c <- txt, isAscii c])

qBytes :: String -> [Word8]
qBytes [] = []
qBytes ('_' : r) = 0x20 : qBytes r
qBytes ('=' : a : b : r)
  | isHex a && isHex b = fromIntegral (hexVal a `shiftL` 4 .|. hexVal b) : qBytes r
qBytes (c : r) = B.unpack (encodeUtf8 [c]) ++ qBytes r

data Item = Enc String | Spc String | Cmt | Lit String

-- | Decode a header value that may contain encoded words.  Whitespace between
-- two adjacent encoded words is dropped.
decodeUnstructured :: String -> String
decodeUnstructured = render . merge . items False

-- | Like 'decodeUnstructured', but also drops comments (leaving one space) and
-- takes quoted strings literally.  Used for the phrase of an address.
decodeDisplay :: String -> String
decodeDisplay = render . merge . items True

items :: Bool -> String -> [Item]
items display = go
  where
    go [] = []
    go s@(c : cs)
      | Just (t, _, r) <- matchEncodedWord s = Enc t : go r
      | display, c == '(' = Cmt : go (snd (skipComment cs))
      | display, c == '"' = let (t, _, r) = quotedString cs in Lit t : go r
      | isBlank c = Spc [c] : go cs
      | otherwise = Lit [c] : go cs

merge :: [Item] -> [Item]
merge (Spc a : Spc b : r) = merge (Spc (a ++ b) : r)
merge (Lit a : Lit b : r) = merge (Lit (a ++ b) : r)
merge (x : r) = x : merge r
merge [] = []

render :: [Item] -> String
render = stripBlanks . go False
  where
    go _ [] = []
    go prevEnc (it : rest) = case it of
      Enc t -> t ++ go True rest
      Lit t -> t ++ go False rest
      Spc t
        | prevEnc, isEnc rest -> go False rest
        | otherwise -> t ++ go False rest
      Cmt
        | prevEnc, isEnc rest -> go False rest
        | otherwise -> ' ' : go False rest
    isEnc (Enc _ : _) = True
    isEnc _ = False
