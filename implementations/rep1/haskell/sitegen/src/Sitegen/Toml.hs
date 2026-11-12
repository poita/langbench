{-# LANGUAGE OverloadedStrings #-}

-- | A reader for the small TOML subset used by @site.toml@ and by the front
-- matter of content files.
--
-- A document is a sequence of lines, each blank, a comment, or an assignment
-- @key = value@ where the value is a basic string, an integer, a boolean, or
-- a one-line array of strings. There are no tables, dotted keys or
-- multi-line values.
module Sitegen.Toml
  ( TomlValue (..)
  , TomlDoc
  , parseToml
  , lookupString
  , lookupInt
  , lookupBool
  , lookupStrings
  ) where

import Data.Char (chr, digitToInt, isDigit, isHexDigit)
import Data.Text (Text)
import qualified Data.Text as T

-- | A value of the subset.
data TomlValue
  = TomlString Text
  | TomlInt Integer
  | TomlBool Bool
  | TomlArray [Text]
  deriving (Eq, Show)

-- | A parsed document: its assignments in file order.
type TomlDoc = [(Text, TomlValue)]

-- | Parse a document. The error message names the offending line.
parseToml :: Text -> Either String TomlDoc
parseToml doc = go (1 :: Int) (T.splitOn "\n" doc) []
  where
    go _ [] acc = Right (reverse acc)
    go n (l : ls) acc = case parseLine l of
      Left err -> Left ("line " ++ show n ++ ": " ++ err)
      Right Nothing -> go (n + 1) ls acc
      Right (Just kv@(k, _))
        | k `elem` map fst acc -> Left ("line " ++ show n ++ ": duplicate key " ++ T.unpack k)
        | otherwise -> go (n + 1) ls (kv : acc)

isBlank :: Char -> Bool
isBlank c = c == ' ' || c == '\t'

parseLine :: Text -> Either String (Maybe (Text, TomlValue))
parseLine raw
  | T.null t || T.head t == '#' = Right Nothing
  | otherwise = do
      let (key, r1) = T.span isKeyChar t
      if T.null key then Left "expected a key" else Right ()
      r2 <- case T.uncons (T.dropWhile isBlank r1) of
        Just ('=', r) -> Right (T.dropWhile isBlank r)
        _ -> Left "expected '='"
      (v, r3) <- parseValue r2
      let r4 = T.dropWhile isBlank r3
      if T.null r4 || T.head r4 == '#' then Right (Just (key, v)) else Left "unexpected text after value"
  where
    t = T.dropWhile isBlank raw
    isKeyChar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit c || c == '_' || c == '-'

parseValue :: Text -> Either String (TomlValue, Text)
parseValue t = case T.uncons t of
  Just ('"', r) -> do
    (s, rest) <- parseString r
    Right (TomlString s, rest)
  Just ('[', r) -> parseArray r
  _
    | Just r <- T.stripPrefix "true" t, endsValue r -> Right (TomlBool True, r)
    | Just r <- T.stripPrefix "false" t, endsValue r -> Right (TomlBool False, r)
    | otherwise -> parseInt t
  where
    endsValue r = T.null r || isBlank (T.head r) || T.head r == '#'

parseInt :: Text -> Either String (TomlValue, Text)
parseInt t =
  let (neg, r) = case T.uncons t of
        Just ('-', x) -> (True, x)
        _ -> (False, t)
      (ds, rest) = T.span isDigit r
   in if T.null ds || (T.length ds > 1 && T.head ds == '0')
        then Left "invalid value"
        else
          let n = T.foldl' (\a c -> a * 10 + toInteger (digitToInt c)) 0 ds
           in Right (TomlInt (if neg then negate n else n), rest)

-- | Parse the rest of a basic string after its opening quote.
parseString :: Text -> Either String (Text, Text)
parseString = go []
  where
    go acc t = case T.uncons t of
      Nothing -> Left "unterminated string"
      Just ('"', r) -> Right (T.pack (reverse acc), r)
      Just ('\\', r) -> case T.uncons r of
        Just ('"', r') -> go ('"' : acc) r'
        Just ('\\', r') -> go ('\\' : acc) r'
        Just ('n', r') -> go ('\n' : acc) r'
        Just ('t', r') -> go ('\t' : acc) r'
        Just ('r', r') -> go ('\r' : acc) r'
        Just ('u', r') ->
          let (hex, r'') = T.splitAt 4 r'
           in if T.length hex == 4 && T.all isHexDigit hex
                then go (chr (T.foldl' (\a c -> a * 16 + digitToInt c) 0 hex) : acc) r''
                else Left "invalid \\u escape"
        _ -> Left "invalid escape"
      Just (c, r) -> go (c : acc) r

parseArray :: Text -> Either String (TomlValue, Text)
parseArray = go []
  where
    go acc t0 =
      let t = T.dropWhile isBlank t0
       in case T.uncons t of
            Just (']', r) -> Right (TomlArray (reverse acc), r)
            Just ('"', r) -> do
              (s, r') <- parseString r
              let r'' = T.dropWhile isBlank r'
              case T.uncons r'' of
                Just (',', x) -> go (s : acc) x
                Just (']', x) -> Right (TomlArray (reverse (s : acc)), x)
                _ -> Left "expected ',' or ']'"
            _ -> Left "expected a string or ']'"

-- | Look up a string-valued key.
lookupString :: Text -> TomlDoc -> Maybe Text
lookupString k doc = case lookup k doc of
  Just (TomlString s) -> Just s
  _ -> Nothing

-- | Look up an integer-valued key.
lookupInt :: Text -> TomlDoc -> Maybe Integer
lookupInt k doc = case lookup k doc of
  Just (TomlInt i) -> Just i
  _ -> Nothing

-- | Look up a boolean-valued key.
lookupBool :: Text -> TomlDoc -> Maybe Bool
lookupBool k doc = case lookup k doc of
  Just (TomlBool b) -> Just b
  _ -> Nothing

-- | Look up an array-of-strings key.
lookupStrings :: Text -> TomlDoc -> Maybe [Text]
lookupStrings k doc = case lookup k doc of
  Just (TomlArray xs) -> Just xs
  _ -> Nothing
