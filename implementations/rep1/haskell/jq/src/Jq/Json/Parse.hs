{-# LANGUAGE BangPatterns #-}
-- | A hand-written, strict JSON parser (RFC 8259) over UTF-8 bytes.
module Jq.Json.Parse
  ( parseJson
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Char (chr)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import Data.Word (Word8)
import Jq.Number (decimalToDouble)
import Jq.Value

type Result a = Either String (a, Int)

-- | Parse exactly one JSON value, allowing surrounding whitespace.
--
-- Numbers are converted with correct rounding; objects keep document order.
parseJson :: B.ByteString -> Either String Value
parseJson bs = do
  (v, i) <- value bs (skipWs bs 0)
  let j = skipWs bs i
  if j == B.length bs
    then Right v
    else Left ("trailing characters at offset " ++ show j)

skipWs :: B.ByteString -> Int -> Int
skipWs bs = go
  where
    n = B.length bs
    go !i
      | i < n, let c = BU.unsafeIndex bs i, c == 32 || c == 10 || c == 13 || c == 9 = go (i + 1)
      | otherwise = i

peek :: B.ByteString -> Int -> Maybe Word8
peek bs i
  | i < B.length bs = Just (BU.unsafeIndex bs i)
  | otherwise = Nothing

value :: B.ByteString -> Int -> Result Value
value bs i = case peek bs i of
  Nothing -> Left "unexpected end of input"
  Just c
    | c == 123 -> object bs (skipWs bs (i + 1))
    | c == 91 -> array bs (skipWs bs (i + 1))
    | c == 34 -> do
        (s, j) <- str bs (i + 1)
        Right (VString s, j)
    | c == 116 -> lit "true" (VBool True)
    | c == 102 -> lit "false" (VBool False)
    | c == 110 -> lit "null" VNull
    | c == 45 || (c >= 48 && c <= 57) -> number bs i
    | otherwise -> Left ("unexpected character at offset " ++ show i)
  where
    lit w v =
      let k = length w
       in if B.take k (B.drop i bs) == B.pack (map (fromIntegral . fromEnum) w)
            then Right (v, i + k)
            else Left ("bad literal at offset " ++ show i)

object :: B.ByteString -> Int -> Result Value
object bs i0 = case peek bs i0 of
  Just 125 -> Right (VObject emptyObject, i0 + 1)
  _ -> go i0 []
  where
    go i acc = case peek bs i of
      Just 34 -> do
        (k, j) <- str bs (i + 1)
        let j' = skipWs bs j
        case peek bs j' of
          Just 58 -> do
            (v, l) <- value bs (skipWs bs (j' + 1))
            let l' = skipWs bs l
                acc' = (k, v) : acc
            case peek bs l' of
              Just 44 -> go (skipWs bs (l' + 1)) acc'
              Just 125 -> Right (VObject (objFromList (reverse acc')), l' + 1)
              _ -> Left ("expected , or } at offset " ++ show l')
          _ -> Left ("expected : at offset " ++ show j')
      _ -> Left ("expected string key at offset " ++ show i)

array :: B.ByteString -> Int -> Result Value
array bs i0 = case peek bs i0 of
  Just 93 -> Right (VArray Seq.empty, i0 + 1)
  _ -> go i0 []
  where
    go i acc = do
      (v, j) <- value bs i
      let j' = skipWs bs j
          acc' = v : acc
      case peek bs j' of
        Just 44 -> go (skipWs bs (j' + 1)) acc'
        Just 93 -> Right (VArray (Seq.fromList (reverse acc')), j' + 1)
        _ -> Left ("expected , or ] at offset " ++ show j')

-- | Parse a string body; the index is just after the opening quote.
str :: B.ByteString -> Int -> Result Text
str bs start = go start start []
  where
    n = B.length bs
    chunk s e = TE.decodeUtf8With TE.lenientDecode (B.take (e - s) (B.drop s bs))
    finish s e acc = case acc of
      [] -> chunk s e
      _ -> T.concat (reverse (chunk s e : acc))
    go !s !i acc
      | i >= n = Left "unterminated string"
      | c == 34 = Right (finish s i acc, i + 1)
      | c == 92 = escape s i acc
      | otherwise = go s (i + 1) acc
      where
        c = BU.unsafeIndex bs i
    escape s i acc = case peek bs (i + 1) of
      Nothing -> Left "unterminated escape"
      Just e
        | e == 117 -> do
            cp <- hex4 (i + 2)
            if cp >= 0xD800 && cp < 0xDC00
              then case (peek bs (i + 6), peek bs (i + 7)) of
                (Just 92, Just 117) -> do
                  lo <- hex4 (i + 8)
                  if lo >= 0xDC00 && lo < 0xE000
                    then emit s i (i + 12) acc (0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00))
                    else emit s i (i + 6) acc 0xFFFD
                _ -> emit s i (i + 6) acc 0xFFFD
              else emit s i (i + 6) acc (if cp >= 0xDC00 && cp < 0xE000 then 0xFFFD else cp)
        | otherwise -> case simple e of
            Just ch -> go' s i (i + 2) acc ch
            Nothing -> Left ("bad escape at offset " ++ show i)
    emit s i next acc cp = go' s i next acc (chr cp)
    go' s i next acc ch = go next next (T.singleton ch : chunk s i : acc)
    simple e = case e of
      34 -> Just '"'
      92 -> Just '\\'
      47 -> Just '/'
      98 -> Just '\b'
      102 -> Just '\f'
      110 -> Just '\n'
      114 -> Just '\r'
      116 -> Just '\t'
      _ -> Nothing
    hex4 j
      | j + 4 <= n = foldl step (Right 0) [j .. j + 3]
      | otherwise = Left "truncated \\u escape"
      where
        step (Left e) _ = Left e
        step (Right a) k = case hexVal (BU.unsafeIndex bs k) of
          Just d -> Right (a * 16 + d)
          Nothing -> Left "bad hex digit"
    hexVal w
      | w >= 48 && w <= 57 = Just (fromIntegral w - 48)
      | w >= 97 && w <= 102 = Just (fromIntegral w - 87)
      | w >= 65 && w <= 70 = Just (fromIntegral w - 55)
      | otherwise = Nothing

number :: B.ByteString -> Int -> Result Value
number bs i0 =
  let neg = peek bs i0 == Just 45
      i1 = if neg then i0 + 1 else i0
      i2 = digitsEnd i1
   in if i2 == i1
        then Left ("bad number at offset " ++ show i0)
        else do
          (i3, fracLen) <- case peek bs i2 of
            Just 46 ->
              let e = digitsEnd (i2 + 1)
               in if e == i2 + 1 then Left "bad fraction" else Right (e, e - i2 - 1)
            _ -> Right (i2, 0)
          (i4, ex) <- case peek bs i3 of
            Just c | c == 101 || c == 69 -> do
              let sgn = peek bs (i3 + 1)
                  j = if sgn == Just 43 || sgn == Just 45 then i3 + 2 else i3 + 1
                  e = digitsEnd j
              if e == j
                then Left "bad exponent"
                else
                  let mag = toInt (B.take (e - j) (B.drop j bs))
                   in Right (e, if sgn == Just 45 then negate mag else mag)
            _ -> Right (i3, 0)
          let intDigits = B.take (i2 - i1) (B.drop i1 bs)
              fracDigits = B.take fracLen (B.drop (i2 + 1) bs)
              m = toInteger' (B.append intDigits fracDigits)
              d = decimalToDouble m (ex - fracLen)
          Right (VNumber (if neg then negate d else d), i4)
  where
    n = B.length bs
    digitsEnd !i
      | i < n, let c = BU.unsafeIndex bs i, c >= 48 && c <= 57 = digitsEnd (i + 1)
      | otherwise = i
    toInt :: B.ByteString -> Int
    toInt = B.foldl' (\a w -> min 100000000 (a * 10 + fromIntegral w - 48)) 0
    toInteger' :: B.ByteString -> Integer
    toInteger' b
      | B.length b <= 18 = toInteger (B.foldl' (\a w -> a * 10 + fromIntegral w - 48) (0 :: Int) b)
      | otherwise = B.foldl' (\a w -> a * 10 + fromIntegral w - 48) 0 b
