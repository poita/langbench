{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : JsonSchema.Json
-- Description : JSON values, a parser and a renderer.
--
-- A hand-written RFC 8259 parser producing 'Value's whose numbers are exact
-- decimals ('Number').  The derived 'Eq' instance of 'Value' is exactly JSON
-- equality as defined by JSON Schema: types never mix, numbers compare by
-- value, and objects ignore member order.
module JsonSchema.Json
  ( Value (..)
  , ParseError (..)
  , parseJson
  , parseJsonBytes
  , renderJson
  , typeName
  , hashValue
  ) where

import Data.Bits (shiftL, xor)
import Data.Char (chr, isDigit, ord)
import qualified Data.ByteString as B
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE

import JsonSchema.Number

-- | A JSON value.  Objects are maps (member order is not significant).
data Value
  = Null
  | Bool !Bool
  | Num !Number
  | Str !Text
  | Arr [Value]
  | Obj !(M.Map Text Value)
  deriving (Eq, Ord, Show)

-- | A parse failure with a human-readable message and a character offset.
data ParseError = ParseError
  { peOffset :: Int
  , peMessage :: String
  } deriving (Eq, Show)

-- | The JSON Schema type name of a value (@integer@ is reported as @number@).
typeName :: Value -> Text
typeName v = case v of
  Null -> "null"
  Bool _ -> "boolean"
  Num _ -> "number"
  Str _ -> "string"
  Arr _ -> "array"
  Obj _ -> "object"

-- | Parse UTF-8 encoded bytes.
parseJsonBytes :: B.ByteString -> Either ParseError Value
parseJsonBytes = parseJson . TE.decodeUtf8With TE.lenientDecode

-- | Parse exactly one JSON document (surrounding whitespace allowed).
parseJson :: Text -> Either ParseError Value
parseJson input =
  case pValue (skipWs input) of
    Left (rest, msg) -> Left (ParseError (T.length input - T.length rest) msg)
    Right (v, rest) ->
      let rest' = skipWs rest
       in if T.null rest'
            then Right v
            else Left (ParseError (T.length input - T.length rest') "trailing characters after document")

-- Parser plumbing: on failure we return the remaining input and a message.
type P a = Text -> Either (Text, String) (a, Text)

skipWs :: Text -> Text
skipWs = T.dropWhile (\c -> c == ' ' || c == '\n' || c == '\t' || c == '\r')

pValue :: P Value
pValue t = case T.uncons t of
  Nothing -> Left (t, "unexpected end of input")
  Just (c, rest) -> case c of
    '{' -> pObject (skipWs rest)
    '[' -> pArray (skipWs rest)
    '"' -> do
      (s, r) <- pString rest
      pure (Str s, r)
    't' -> literal "true" (Bool True)
    'f' -> literal "false" (Bool False)
    'n' -> literal "null" Null
    _ | c == '-' || isDigit c -> pNumber t
      | otherwise -> Left (t, "unexpected character " ++ show c)
  where
    literal word v = case T.stripPrefix word t of
      Just r -> Right (v, r)
      Nothing -> Left (t, "invalid literal")

pArray :: P Value
pArray t = case T.uncons t of
  Just (']', r) -> Right (Arr [], r)
  _ -> go [] t
  where
    go acc s = do
      (v, r) <- pValue s
      let r' = skipWs r
      case T.uncons r' of
        Just (',', r2) -> go (v : acc) (skipWs r2)
        Just (']', r2) -> Right (Arr (reverse (v : acc)), r2)
        _ -> Left (r', "expected ',' or ']'")

pObject :: P Value
pObject t = case T.uncons t of
  Just ('}', r) -> Right (Obj M.empty, r)
  _ -> go [] t
  where
    go acc s = case T.uncons s of
      Just ('"', s1) -> do
        (k, s2) <- pString s1
        let s3 = skipWs s2
        case T.uncons s3 of
          Just (':', s4) -> do
            (v, s5) <- pValue (skipWs s4)
            let s6 = skipWs s5
                acc' = (k, v) : acc
            case T.uncons s6 of
              Just (',', s7) -> go acc' (skipWs s7)
              Just ('}', s7) -> Right (Obj (M.fromList (reverse acc')), s7)
              _ -> Left (s6, "expected ',' or '}'")
          _ -> Left (s3, "expected ':'")
      _ -> Left (s, "expected string key")

-- | Parse the remainder of a string whose opening quote was consumed.
pString :: P Text
pString = go []
  where
    go acc t =
      let (plain, rest) = T.span (\c -> c /= '"' && c /= '\\' && c >= ' ') t
          acc' = if T.null plain then acc else plain : acc
       in case T.uncons rest of
            Nothing -> Left (rest, "unterminated string")
            Just ('"', r) -> Right (T.concat (reverse acc'), r)
            Just ('\\', r) -> case T.uncons r of
              Nothing -> Left (r, "unterminated escape")
              Just (e, r1) -> case e of
                '"' -> go (T.singleton '"' : acc') r1
                '\\' -> go (T.singleton '\\' : acc') r1
                '/' -> go (T.singleton '/' : acc') r1
                'b' -> go (T.singleton '\b' : acc') r1
                'f' -> go (T.singleton '\f' : acc') r1
                'n' -> go (T.singleton '\n' : acc') r1
                'r' -> go (T.singleton '\r' : acc') r1
                't' -> go (T.singleton '\t' : acc') r1
                'u' -> do
                  (cp, r2) <- hex4 r1
                  if cp >= 0xD800 && cp < 0xDC00
                    then case T.stripPrefix "\\u" r2 of
                      Just r3 -> do
                        (lo, r4) <- hex4 r3
                        if lo >= 0xDC00 && lo < 0xE000
                          then go (T.singleton (chr (0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00))) : acc') r4
                          else go (T.singleton '\xFFFD' : acc') r2
                      Nothing -> go (T.singleton '\xFFFD' : acc') r2
                    else
                      if cp >= 0xDC00 && cp < 0xE000
                        then go (T.singleton '\xFFFD' : acc') r2
                        else go (T.singleton (chr cp) : acc') r2
                _ -> Left (r, "invalid escape")
            Just (_, _) -> Left (rest, "control character in string")
    hex4 t =
      let (h, r) = T.splitAt 4 t
       in if T.length h == 4 && T.all isHex h
            then Right (T.foldl' (\a c -> a * 16 + hexVal c) 0 h, r)
            else Left (t, "invalid \\u escape")
    isHex c = isDigit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
    hexVal c
      | isDigit c = ord c - ord '0'
      | c >= 'a' = ord c - ord 'a' + 10
      | otherwise = ord c - ord 'A' + 10

pNumber :: P Value
pNumber t0 = do
  let (neg, t1) = case T.uncons t0 of
        Just ('-', r) -> (True, r)
        _ -> (False, t0)
      (intDigits, t2) = T.span isDigit t1
  if T.null intDigits
    then Left (t1, "expected digit")
    else
      if T.length intDigits > 1 && T.head intDigits == '0'
        then Left (t1, "leading zero")
        else do
          (fracDigits, t3) <- case T.uncons t2 of
            Just ('.', r) ->
              let (d, r') = T.span isDigit r
               in if T.null d then Left (r, "expected digit after '.'") else Right (d, r')
            _ -> Right (T.empty, t2)
          (ex, t4) <- case T.uncons t3 of
            Just (c, r) | c == 'e' || c == 'E' -> do
              let (sgn, r1) = case T.uncons r of
                    Just ('+', x) -> (1, x)
                    Just ('-', x) -> (-1, x)
                    _ -> (1 :: Int, r)
                  (d, r2) = T.span isDigit r1
              if T.null d
                then Left (r1, "expected exponent digits")
                else Right (sgn * digitsToInt d, r2)
            _ -> Right (0, t3)
          let m = digitsToInteger (T.append intDigits fracDigits)
              m' = if neg then negate m else m
          pure (Num (mkNumber m' (ex - T.length fracDigits)), t4)

digitsToInteger :: Text -> Integer
digitsToInteger = T.foldl' (\a c -> a * 10 + toInteger (ord c - 48)) 0

digitsToInt :: Text -> Int
digitsToInt = T.foldl' (\a c -> min 100000000 (a * 10 + (ord c - 48))) 0

-- | Render a value as compact JSON text.
renderJson :: Value -> Text
renderJson v = T.concat (go v [])
  where
    go val rest = case val of
      Null -> "null" : rest
      Bool True -> "true" : rest
      Bool False -> "false" : rest
      Num n -> T.pack (showNumber n) : rest
      Str s -> quote s : rest
      Arr xs -> "[" : commaSep (map go xs) ("]" : rest)
      Obj m -> "{" : commaSep [\r -> quote k : ":" : go x r | (k, x) <- M.toList m] ("}" : rest)
    commaSep [] rest = rest
    commaSep (f : fs) rest = f (foldr (\g r -> "," : g r) rest fs)
    quote s = T.concat ["\"", T.concatMap esc s, "\""]
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _ | c < ' ' -> T.pack ("\\u" ++ pad (hex (ord c)))
        | otherwise -> T.singleton c
    hex 0 = ""
    hex n = hex (n `div` 16) ++ ["0123456789abcdef" !! (n `mod` 16)]
    pad s = replicate (4 - length s) '0' ++ s

-- | A hash consistent with JSON equality: equal values hash equally
-- (numbers are canonical, objects are key-ordered maps).
hashValue :: Value -> Int
hashValue v = case v of
  Null -> 1
  Bool b -> if b then 3 else 2
  Num n -> mix 5 (fromInteger (mantissa n)) `mix` exponent10 n
  Str s -> T.foldl' (\h c -> mix h (ord c)) 7 s
  Arr xs -> foldl' (\h x -> mix h (hashValue x)) 11 xs
  Obj m -> M.foldlWithKey' (\h k x -> mix (mix h (hashValue (Str k))) (hashValue x)) 13 m
  where
    mix :: Int -> Int -> Int
    mix h x = (h `shiftL` 5 + h) `xor` x
