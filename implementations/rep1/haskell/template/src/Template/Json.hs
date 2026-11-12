{-# LANGUAGE OverloadedStrings #-}
-- | A small recursive-descent JSON parser producing template values.
--
-- Numbers without a fraction or exponent become integers, all other numbers
-- floats; object members keep document order.
module Template.Json
  ( parseJson
  ) where

import Data.Char (chr, isDigit, isHexDigit, digitToInt)
import Data.Ratio ((%))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T

import Template.Value

type Result a = Either String (a, Text)

-- | Parse a complete JSON document.
parseJson :: Text -> Either String Value
parseJson t = do
  (v, rest) <- value t
  if T.all isJsonWs rest then Right v else Left "trailing characters after JSON value"

isJsonWs :: Char -> Bool
isJsonWs c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

skip :: Text -> Text
skip = T.dropWhile isJsonWs

value :: Text -> Result Value
value t0 = case T.uncons t of
  Nothing -> Left "unexpected end of JSON"
  Just (c, r)
    | c == '{' -> object r
    | c == '[' -> array r
    | c == '"' -> do
        (s, rest) <- stringBody r
        Right (VStr s, rest)
    | c == '-' || isDigit c -> number t
    | Just rest <- T.stripPrefix "true" t -> Right (VBool True, rest)
    | Just rest <- T.stripPrefix "false" t -> Right (VBool False, rest)
    | Just rest <- T.stripPrefix "null" t -> Right (VNone, rest)
    | otherwise -> Left ("unexpected character in JSON: " ++ [c])
  where
    t = skip t0

object :: Text -> Result Value
object t0 = case T.uncons (skip t0) of
  Just ('}', r) -> Right (VDict (dictFromList []), r)
  _ -> go [] t0
  where
    go acc t = do
      let t1 = skip t
      (k, t2) <- case T.uncons t1 of
        Just ('"', r) -> stringBody r
        _ -> Left "expected object key"
      t3 <- case T.uncons (skip t2) of
        Just (':', r) -> Right r
        _ -> Left "expected ':'"
      (v, t4) <- value t3
      let acc' = (k, v) : acc
      case T.uncons (skip t4) of
        Just (',', r) -> go acc' r
        Just ('}', r) -> Right (VDict (dictFromList (reverse acc')), r)
        _ -> Left "expected ',' or '}'"

array :: Text -> Result Value
array t0 = case T.uncons (skip t0) of
  Just (']', r) -> Right (VList Seq.empty, r)
  _ -> go [] t0
  where
    go acc t = do
      (v, t1) <- value t
      let acc' = v : acc
      case T.uncons (skip t1) of
        Just (',', r) -> go acc' r
        Just (']', r) -> Right (VList (Seq.fromList (reverse acc')), r)
        _ -> Left "expected ',' or ']'"

-- Parse a string body whose opening quote has been consumed.
stringBody :: Text -> Result Text
stringBody = go []
  where
    go acc s =
      let (chunk, r) = T.break (\c -> c == '"' || c == '\\') s
      in case T.uncons r of
        Nothing -> Left "unterminated JSON string"
        Just ('"', rest) -> Right (T.concat (reverse (chunk : acc)), rest)
        Just (_, r1) -> case T.uncons r1 of
          Nothing -> Left "unterminated JSON string"
          Just (e, r2) -> case e of
            '"' -> go ("\"" : chunk : acc) r2
            '\\' -> go ("\\" : chunk : acc) r2
            '/' -> go ("/" : chunk : acc) r2
            'b' -> go ("\b" : chunk : acc) r2
            'f' -> go ("\f" : chunk : acc) r2
            'n' -> go ("\n" : chunk : acc) r2
            'r' -> go ("\r" : chunk : acc) r2
            't' -> go ("\t" : chunk : acc) r2
            'u' -> do
              (cp, r3) <- hex4 r2
              if cp >= 0xD800 && cp < 0xDC00
                then case T.stripPrefix "\\u" r3 of
                  Just r4 -> do
                    (lo, r5) <- hex4 r4
                    if lo >= 0xDC00 && lo < 0xE000
                      then go (T.singleton (chr (0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00))) : chunk : acc) r5
                      else go ("\xFFFD" : chunk : acc) r3
                  Nothing -> go ("\xFFFD" : chunk : acc) r3
                else if cp >= 0xDC00 && cp < 0xE000
                  then go ("\xFFFD" : chunk : acc) r3
                  else go (T.singleton (chr cp) : chunk : acc) r3
            _ -> Left "bad escape in JSON string"
    hex4 s =
      let (h, r) = T.splitAt 4 s
      in if T.length h == 4 && T.all isHexDigit h
           then Right (T.foldl' (\a c -> a * 16 + digitToInt c) 0 h, r)
           else Left "bad \\u escape in JSON string"

number :: Text -> Result Value
number t0 = do
  let (neg, t1) = case T.uncons t0 of
        Just ('-', r) -> (True, r)
        _ -> (False, t0)
      (ip, t2) = T.span isDigit t1
  if T.null ip then Left "bad JSON number" else Right ()
  let (fp, hasFrac, t3) = case T.uncons t2 of
        Just ('.', r) -> let (f, r') = T.span isDigit r in (f, True, r')
        _ -> (T.empty, False, t2)
  if hasFrac && T.null fp then Left "bad JSON number" else Right ()
  (ex, hasExp, t4) <- case T.uncons t3 of
    Just (e, r) | e == 'e' || e == 'E' ->
      let (sgn, r1) = case T.uncons r of
            Just ('+', x) -> (1, x)
            Just ('-', x) -> (-1, x)
            _ -> (1 :: Integer, r)
          (ds, r2) = T.span isDigit r1
      in if T.null ds then Left "bad JSON number"
         else Right (sgn * read (T.unpack ds), True, r2)
    _ -> Right (0, False, t3)
  let sign = if neg then -1 else 1 :: Integer
  if not hasFrac && not hasExp
    then Right (VInt (sign * read (T.unpack ip)), t4)
    else do
      let m = read (T.unpack (ip <> fp)) :: Integer
          scale = ex - fromIntegral (T.length fp)
          q = if scale >= 0 then fromInteger (m * 10 ^ scale) else m % (10 ^ negate scale)
          d = fromRational q :: Double
      Right (VFloat (if neg then negate d else d), t4)
