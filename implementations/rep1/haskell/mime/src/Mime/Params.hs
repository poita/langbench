-- | Structured header values (@Content-Type@ and friends) with RFC 2231
-- parameter continuations and extended values.
module Mime.Params
  ( Structured (..)
  , parseStructured
  , paramLookup
  ) where

import qualified Data.ByteString as B
import Data.Char (isDigit)
import Data.List (sortOn)

import Mime.Charset (decode, encodeUtf8)
import Mime.EncodedWord (decodeUnstructured)
import Mime.Lexical

-- | A parsed structured value: the text before the first @;@ and the raw
-- parameters in order of first appearance.
data Structured = Structured
  { structValue :: String
  , structParams :: [(String, String)]
  }
  deriving (Eq, Show)

-- | Parse a value such as @text/plain; charset=utf-8@.  Parentheses are
-- ordinary characters.
parseStructured :: String -> Structured
parseStructured s = case splitSegments s of
  [] -> Structured "" []
  v : ps -> Structured v (dedupe [p | Just p <- map param ps])
  where
    dedupe = go []
      where
        go _ [] = []
        go seen ((k, v) : r)
          | k `elem` seen = go seen r
          | otherwise = (k, v) : go (k : seen) r
    param seg = case break (== '=') seg of
      (_, []) -> Nothing
      (n, _ : v) ->
        let v' = stripBlanks v
            val = case v' of
              '"' : r -> let (t, _, _) = quotedString r in t
              _ -> v'
         in Just (lowerStr (stripBlanks n), val)

-- | Split at every semicolon outside a quoted string (segments keep their raw
-- text).
splitSegments :: String -> [String]
splitSegments = go []
  where
    go acc [] = [reverse acc]
    go acc (c : r) = case c of
      ';' -> reverse acc : go [] r
      '"' -> quoted (c : acc) r
      _ -> go (c : acc) r
    quoted acc [] = [reverse acc]
    quoted acc ('"' : r) = go ('"' : acc) r
    quoted acc ('\\' : c : r) = quoted (c : '\\' : acc) r
    quoted acc (c : r) = quoted (c : acc) r

data Raw
  = Plain String
  | Seg Integer Bool String -- number, extended?, value
  | Ext String

-- | Look up an effective parameter value (name must be lower-case).
paramLookup :: String -> Structured -> Maybe String
paramLookup base (Structured _ ps)
  | not (null segs) = Just (assembleSegments segs)
  | (v : _) <- [v | (_, Ext v) <- classified] = Just (decodeExtended v)
  | (v : _) <- [v | (_, Plain v) <- classified] = Just (decodeUnstructured v)
  | otherwise = Nothing
  where
    classified = [(b, r) | (n, v) <- ps, let (b, r) = classify n v, b == base]
    segs = [(n, e, v) | (_, Seg n e v) <- classified]

classify :: String -> String -> (String, Raw)
classify name v = case reverse name of
  '*' : r1 | (ds@(_ : _), '*' : r2@(_ : _)) <- span isDigit r1 ->
    (reverse r2, Seg (read (reverse ds)) True v)
  r0 | (ds@(_ : _), '*' : r2@(_ : _)) <- span isDigit r0 ->
    (reverse r2, Seg (read (reverse ds)) False v)
  '*' : r1@(_ : _) -> (reverse r1, Ext v)
  _ -> (name, Plain v)

assembleSegments :: [(Integer, Bool, String)] -> String
assembleSegments segs = decode charset (B.concat parts)
  where
    firstOfEach = go [] segs
      where
        go _ [] = []
        go seen (s@(n, _, _) : r)
          | n `elem` seen = go seen r
          | otherwise = s : go (n : seen) r
    ordered = sortOn (\(n, _, _) -> n) firstOfEach
    charset = case [v | (0, True, v) <- ordered] of
      v : _ -> fst (splitExtended v)
      [] -> "us-ascii"
    parts = [piece n e v | (n, e, v) <- ordered]
    piece n e v
      | not e = encodeUtf8 v
      | n == 0 = percentDecode (snd (splitExtended v))
      | otherwise = percentDecode v

decodeExtended :: String -> String
decodeExtended v = let (cs, t) = splitExtended v in decode cs (percentDecode t)

-- | Split @charset'language'text@; with fewer than two quotes the whole value
-- is the text.  An empty charset means us-ascii.
splitExtended :: String -> (String, String)
splitExtended v = case break (== '\'') v of
  (cs, '\'' : r) -> case break (== '\'') r of
    (_, '\'' : t) -> (if null cs then "us-ascii" else cs, t)
    _ -> ("us-ascii", v)
  _ -> ("us-ascii", v)

percentDecode :: String -> B.ByteString
percentDecode = B.concat . go
  where
    go [] = []
    go ('%' : a : b : r) | isHex a && isHex b = B.singleton (fromIntegral (hexVal a * 16 + hexVal b)) : go r
    go (c : r) = encodeUtf8 [c] : go r
