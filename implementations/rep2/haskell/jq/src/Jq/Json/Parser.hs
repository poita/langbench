-- | A hand-written RFC 8259 JSON parser over UTF-8 'ByteString's.
module Jq.Json.Parser
  ( parseJson
  , decodeHex4
  ) where

import qualified Data.ByteString as B
import Data.ByteString (ByteString)
import Data.Char (chr)
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import Data.Word (Word8)

import Jq.Number (scanNumber)
import Jq.Value

type Result a = Either String (a, Int)

-- | Parse exactly one JSON value, allowing surrounding whitespace.
parseJson :: ByteString -> Either String Value
parseJson bs = do
  (v, i) <- value bs (skipWs bs 0)
  let j = skipWs bs i
  if j == B.length bs then Right v else Left ("trailing characters at offset " ++ show j)

skipWs :: ByteString -> Int -> Int
skipWs bs = go
  where
    n = B.length bs
    go i | i < n, let w = B.index bs i, w == 32 || w == 9 || w == 10 || w == 13 = go (i + 1)
         | otherwise = i

peekAt :: ByteString -> Int -> Word8
peekAt bs i = if i < B.length bs then B.index bs i else 0

value :: ByteString -> Int -> Result Value
value bs i = case peekAt bs i of
  123 -> object bs (skipWs bs (i + 1))
  91  -> array bs (skipWs bs (i + 1))
  34  -> do (t, j) <- string bs (i + 1); pure (VStr t, j)
  116 -> lit "true" (VBool True)
  102 -> lit "false" (VBool False)
  110 -> lit "null" VNull
  w | w == 45 || (w >= 48 && w <= 57) -> case scanNumber bs i of
        Just (d, j) -> Right (VNum d, j)
        Nothing -> Left ("invalid number at offset " ++ show i)
  _ -> Left ("unexpected character at offset " ++ show i)
  where
    lit s v
      | B.isPrefixOf s (B.drop i bs) = Right (v, i + B.length s)
      | otherwise = Left ("invalid literal at offset " ++ show i)

array :: ByteString -> Int -> Result Value
array bs i0
  | peekAt bs i0 == 93 = Right (VArr Seq.empty, i0 + 1)
  | otherwise = go i0 []
  where
    go i acc = do
      (v, j) <- value bs i
      let k = skipWs bs j
      case peekAt bs k of
        44 -> go (skipWs bs (k + 1)) (v : acc)
        93 -> Right (VArr (Seq.fromList (reverse (v : acc))), k + 1)
        _  -> Left ("expected ',' or ']' at offset " ++ show k)

object :: ByteString -> Int -> Result Value
object bs i0
  | peekAt bs i0 == 125 = Right (VObj emptyObject, i0 + 1)
  | otherwise = go i0 emptyObject
  where
    go i o
      | peekAt bs i /= 34 = Left ("expected string key at offset " ++ show i)
      | otherwise = do
          (k, j) <- string bs (i + 1)
          let j' = skipWs bs j
          if peekAt bs j' /= 58 then Left ("expected ':' at offset " ++ show j') else do
            (v, l) <- value bs (skipWs bs (j' + 1))
            let o' = objectInsert k v o
                m = skipWs bs l
            case peekAt bs m of
              44 -> go (skipWs bs (m + 1)) o'
              125 -> Right (VObj o', m + 1)
              _ -> Left ("expected ',' or '}' at offset " ++ show m)

decodeUtf8Lenient :: ByteString -> Text
decodeUtf8Lenient = TE.decodeUtf8With TE.lenientDecode

-- | Parse a string body; the offset is just past the opening quote.
string :: ByteString -> Int -> Result Text
string bs start = go start []
  where
    n = B.length bs
    special w = w == 34 || w == 92
    go p acc =
      case B.findIndex special (B.drop p bs) of
        Nothing -> Left "unterminated string"
        Just off ->
          let q = p + off
              chunk = decodeUtf8Lenient (B.take off (B.drop p bs))
          in if B.index bs q == 34
               then Right (if null acc then chunk else T.concat (reverse (chunk : acc)), q + 1)
               else escape q (chunk : acc)
    escape q acc
      | q + 1 >= n = Left "unterminated escape"
      | otherwise = case B.index bs (q + 1) of
          34  -> go (q + 2) (T.singleton '"' : acc)
          92  -> go (q + 2) (T.singleton '\\' : acc)
          47  -> go (q + 2) (T.singleton '/' : acc)
          98  -> go (q + 2) (T.singleton '\b' : acc)
          102 -> go (q + 2) (T.singleton '\f' : acc)
          110 -> go (q + 2) (T.singleton '\n' : acc)
          114 -> go (q + 2) (T.singleton '\r' : acc)
          116 -> go (q + 2) (T.singleton '\t' : acc)
          117 -> case decodeHex4 bs (q + 2) of
            Nothing -> Left "invalid \\u escape"
            Just hi
              | hi >= 0xD800 && hi < 0xDC00
              , peekAt bs (q + 6) == 92, peekAt bs (q + 7) == 117
              , Just lo <- decodeHex4 bs (q + 8), lo >= 0xDC00 && lo < 0xE000 ->
                  go (q + 12) (T.singleton (chr (0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00))) : acc)
              | otherwise -> go (q + 6) (T.singleton (safeChr hi) : acc)
          _ -> Left "invalid escape"
    safeChr c = if c >= 0xD800 && c < 0xE000 then '\xFFFD' else chr c

-- | Decode four hex digits (either case) at the given offset.
decodeHex4 :: ByteString -> Int -> Maybe Int
decodeHex4 bs i
  | i + 4 > B.length bs = Nothing
  | otherwise = go 0 0
  where
    go :: Int -> Int -> Maybe Int
    go k acc
      | k == 4 = Just acc
      | otherwise = do
          d <- hexVal (B.index bs (i + k))
          go (k + 1) (acc * 16 + d)

hexVal :: Word8 -> Maybe Int
hexVal w
  | w >= 48 && w <= 57 = Just (fromIntegral w - 48)
  | w >= 97 && w <= 102 = Just (fromIntegral w - 87)
  | w >= 65 && w <= 70 = Just (fromIntegral w - 55)
  | otherwise = Nothing
