{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
-- | A TOML 1.0.0 decoder.
--
-- The decoder is a single-pass recursive-descent parser.  Scalars are kept as
-- canonical text (see "Toml.Value"):
--
-- * strings: the string after escape processing;
-- * integers: decimal, whatever base they were written in;
-- * floats: @printf("%.16e")@ form, @inf@, @-inf@ or @nan@;
-- * booleans: @true@ or @false@;
-- * date-times: @T@ separator, fraction without trailing zeros, @Z@ for a
--   zero offset.
module Toml.Decode
  ( decode
  , decodeText
  , DecodeError (..)
  , renderDecodeError
  ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.Char (chr, isAsciiLower, isAsciiUpper, isDigit, isHexDigit, digitToInt)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Toml.Internal.DateTime (isDateShape, isTimeShape, parseDateTime)
import Toml.Internal.Number (parseNumber)
import Toml.Internal.Parser
import Toml.Internal.Tables
import Toml.Value

-- | Why a document was rejected.
data DecodeError = DecodeError
  { errorLine    :: !Int     -- ^ 1-based line where the problem was noticed (0 if unknown)
  , errorMessage :: String
  } deriving (Eq, Show)

renderDecodeError :: DecodeError -> String
renderDecodeError (DecodeError l m)
  | l <= 0 = m
  | otherwise = "line " ++ show l ++ ": " ++ m

-- | Decode a document given as raw bytes, which must be valid UTF-8.
decode :: ByteString -> Either DecodeError Table
decode bs = case TE.decodeUtf8' bs of
  Left _ -> Left (DecodeError 0 "invalid UTF-8")
  Right t -> decodeText t

-- | Decode a document given as text.
decodeText :: Text -> Either DecodeError Table
decodeText t
  | "\xFEFF" `T.isPrefixOf` t = Left (DecodeError 1 "byte order mark")
  | loneCR = Left (DecodeError 0 "carriage return not followed by line feed")
  | otherwise = case runP documentP t of
      Fail msg rest ->
        let consumed = T.take (T.length t - T.length rest) t
        in Left (DecodeError (1 + T.count "\n" consumed) msg)
      Ok root _ -> Right (tblToTable root)
  where
    loneCR = any (\p -> not ("\n" `T.isPrefixOf` p)) (drop 1 (T.splitOn "\r" t))

------------------------------------------------------------------------------
-- Lexical helpers

isWs :: Char -> Bool
isWs c = c == ' ' || c == '\t'

skipWs :: P ()
skipWs = skipWhileP isWs

isBareKeyChar :: Char -> Bool
isBareKeyChar c = isAsciiUpper c || isAsciiLower c || (isDigit c && c < '\x80') || c == '_' || c == '-'

-- | Characters that can occur in a number, boolean or date-time token.
isTokenChar :: Char -> Bool
isTokenChar c = isBareKeyChar c || c == '+' || c == '.' || c == ':'

-- | Consume a comment (the cursor is on the @#@); what follows must be a
-- line end or end of input, which is left in place.
comment :: P ()
comment = do
  dropP 1
  skipWhileP (\c -> c == '\t' || (c >= ' ' && c /= '\DEL'))
  mc <- peekChar
  case mc of
    Nothing -> pure ()
    Just '\n' -> pure ()
    Just '\r' -> pure ()
    Just _ -> failP "invalid character in comment"

-- | Consume a newline (LF or CRLF), or succeed at end of input.
eol :: P ()
eol = do
  mc <- peekChar
  case mc of
    Nothing -> pure ()
    Just '\n' -> dropP 1
    Just '\r' -> dropP 2
    Just _ -> failP "expected end of line"

-- | After a statement: optional whitespace, optional comment, line end.
trailer :: P ()
trailer = do
  skipWs
  mc <- peekChar
  when (mc == Just '#') comment
  eol

-- | Whitespace, newlines and comments (inside arrays).
skipBlank :: P ()
skipBlank = do
  skipWs
  mc <- peekChar
  case mc of
    Just '\n' -> dropP 1 >> skipBlank
    Just '\r' -> dropP 2 >> skipBlank
    Just '#' -> comment >> skipBlank
    _ -> pure ()

------------------------------------------------------------------------------
-- Document structure

documentP :: P Tbl
documentP = go (emptyTbl Explicit) []
  where
    go !root path = do
      skipWs
      mc <- peekChar
      case mc of
        Nothing -> pure root
        Just '\n' -> dropP 1 >> go root path
        Just '\r' -> dropP 2 >> go root path
        Just '#' -> comment >> go root path
        Just '[' -> do
          (root', path') <- header root
          trailer
          go root' path'
        Just _ -> do
          (ks, node) <- keyValue
          root' <- liftE (insertKV path ks node root)
          trailer
          go root' path

header :: Tbl -> P (Tbl, [Text])
header root = do
  dropP 1
  isArr <- lookingAt "["
  if isArr
    then do
      dropP 1
      skipWs
      ks <- keyP
      skipWs
      expectText "]]"
      r <- liftE (openArray ks root)
      pure (r, ks)
    else do
      skipWs
      ks <- keyP
      skipWs
      expectChar ']'
      r <- liftE (openTable ks root)
      pure (r, ks)

keyValue :: P ([Text], Node)
keyValue = do
  ks <- keyP
  skipWs
  expectChar '='
  skipWs
  v <- valueP
  pure (ks, v)

-- | A possibly dotted key.  Trailing whitespace is consumed.
keyP :: P [Text]
keyP = do
  k <- simpleKey
  skipWs
  mc <- peekChar
  if mc == Just '.'
    then do
      dropP 1
      skipWs
      (k :) <$> keyP
    else pure [k]

simpleKey :: P Text
simpleKey = do
  mc <- peekChar
  case mc of
    Just '"' -> basicString
    Just '\'' -> literalString
    _ -> do
      k <- takeWhileP isBareKeyChar
      when (T.null k) (failP "expected a key")
      pure k

------------------------------------------------------------------------------
-- Values

valueP :: P Node
valueP = do
  mc <- peekChar
  case mc of
    Just '"' -> do
      ml <- lookingAt "\"\"\""
      str <$> (if ml then mlBasicString else basicString)
    Just '\'' -> do
      ml <- lookingAt "'''"
      str <$> (if ml then mlLiteralString else literalString)
    Just '[' -> arrayP
    Just '{' -> inlineTableP
    Just _ -> tokenP
    Nothing -> failP "expected a value"
  where
    str = Leaf . VScalar TString

arrayP :: P Node
arrayP = dropP 1 >> go []
  where
    go acc = do
      skipBlank
      mc <- peekChar
      case mc of
        Just ']' -> dropP 1 >> pure (done acc)
        _ -> do
          v <- valueP
          skipBlank
          mc' <- peekChar
          case mc' of
            Just ',' -> dropP 1 >> go (nodeToValue v : acc)
            Just ']' -> dropP 1 >> pure (done (nodeToValue v : acc))
            _ -> failP "expected ',' or ']' in array"
    done = Leaf . VArray . reverse

inlineTableP :: P Node
inlineTableP = do
  dropP 1
  skipWs
  mc <- peekChar
  if mc == Just '}'
    then dropP 1 >> pure (Sub (emptyTbl Inline))
    else go (emptyTbl Inline)
  where
    go !tbl = do
      (ks, v) <- keyValue
      tbl' <- liftE (insertKV [] ks v tbl)
      skipWs
      mc <- peekChar
      case mc of
        Just ',' -> dropP 1 >> skipWs >> go tbl'
        Just '}' -> dropP 1 >> pure (Sub tbl')
        _ -> failP "expected ',' or '}' in inline table"

-- | Booleans, numbers and date-times.
tokenP :: P Node
tokenP = do
  tok <- takeWhileP isTokenChar
  when (T.null tok) (failP "expected a value")
  let s = T.unpack tok
  case s of
    "true" -> scalar TBool "true"
    "false" -> scalar TBool "false"
    _ | isDateShape s -> do
          s' <- if length s == 10 then withTime s else pure s
          typed (parseDateTime s')
      | isTimeShape s -> typed (parseDateTime s)
      | otherwise -> typed (parseNumber s)
  where
    scalar ty = pure . Leaf . VScalar ty . T.pack
    typed = maybe (failP "invalid value") (\(ty, s) -> scalar ty s)
    -- "1979-05-27 07:32:00": a space followed by a digit continues a date-time.
    withTime d = do
      rest <- remaining
      case T.unpack (T.take 2 rest) of
        [' ', c] | isDigit c && c < '\x80' -> do
          dropP 1
          t2 <- takeWhileP isTokenChar
          pure (d ++ "T" ++ T.unpack t2)
        _ -> pure d

------------------------------------------------------------------------------
-- Strings

basicChar :: Char -> Bool
basicChar c = c == '\t' || (c >= ' ' && c /= '"' && c /= '\\' && c /= '\DEL')

literalChar :: Char -> Bool
literalChar c = c == '\t' || (c >= ' ' && c /= '\'' && c /= '\DEL')

-- | Normalise CRLF to LF in a chunk of a multi-line string.
normNl :: Text -> Text
normNl t = if T.any (== '\r') t then T.replace "\r\n" "\n" t else t

basicString :: P Text
basicString = dropP 1 >> go []
  where
    go acc = do
      chunk <- takeWhileP basicChar
      mc <- peekChar
      case mc of
        Just '"' -> dropP 1 >> pure (T.concat (reverse (chunk : acc)))
        Just '\\' -> do
          dropP 1
          c <- escape
          go (T.singleton c : chunk : acc)
        _ -> failP "unterminated string or invalid character"

literalString :: P Text
literalString = do
  dropP 1
  chunk <- takeWhileP literalChar
  expectChar '\''
  pure chunk

-- | Skip the newline directly after an opening multi-line delimiter.
skipFirstNewline :: P ()
skipFirstNewline = do
  lf <- lookingAt "\n"
  crlf <- lookingAt "\r\n"
  if lf then dropP 1 else when crlf (dropP 2)

mlBasicString :: P Text
mlBasicString = dropP 3 >> skipFirstNewline >> go []
  where
    plain c = c == '\n' || c == '\r' || basicChar c
    go acc = do
      chunk <- normNl <$> takeWhileP plain
      mc <- peekChar
      case mc of
        Just '"' -> do
          run <- takeWhileP (== '"')
          let n = T.length run
          if n < 3 then go (run : chunk : acc)
          else if n <= 5 then pure (T.concat (reverse (T.replicate (n - 3) "\"" : chunk : acc)))
          else failP "too many quotes"
        Just '\\' -> do
          dropP 1
          nxt <- peekChar
          case nxt of
            Just c | isWs c || c == '\n' || c == '\r' -> do
              skipWs
              eol' <- peekChar
              case eol' of
                Just '\n' -> dropP 1
                Just '\r' -> dropP 2
                _ -> failP "invalid line-ending backslash"
              skipWhileP (\x -> isWs x || x == '\n' || x == '\r')
              go (chunk : acc)
            _ -> do
              c <- escape
              go (T.singleton c : chunk : acc)
        _ -> failP "unterminated multi-line string or invalid character"

mlLiteralString :: P Text
mlLiteralString = dropP 3 >> skipFirstNewline >> go []
  where
    plain c = c == '\n' || c == '\r' || literalChar c
    go acc = do
      chunk <- normNl <$> takeWhileP plain
      mc <- peekChar
      case mc of
        Just '\'' -> do
          run <- takeWhileP (== '\'')
          let n = T.length run
          if n < 3 then go (run : chunk : acc)
          else if n <= 5 then pure (T.concat (reverse (T.replicate (n - 3) "'" : chunk : acc)))
          else failP "too many quotes"
        _ -> failP "unterminated multi-line literal string or invalid character"

-- | The character after a backslash has to be read; returns the escaped char.
escape :: P Char
escape = do
  c <- nextChar
  case c of
    'b' -> pure '\b'
    't' -> pure '\t'
    'n' -> pure '\n'
    'f' -> pure '\f'
    'r' -> pure '\r'
    '"' -> pure '"'
    '\\' -> pure '\\'
    'u' -> hexScalar 4
    'U' -> hexScalar 8
    _ -> failP "invalid escape sequence"

hexScalar :: Int -> P Char
hexScalar n = do
  ds <- T.unpack <$> takeN n
  when (not (all (\c -> isHexDigit c && c < '\x80') ds)) (failP "invalid hex digit in escape")
  let v = foldl (\a d -> a * 16 + digitToInt d) 0 ds
  when (v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) (failP "invalid unicode scalar")
  pure (chr v)
