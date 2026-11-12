-- |
-- Module      : Spiremark.SExpr
-- Description : Tokeniser and parser for the card-database s-expression syntax.
--
-- The card database is a text file of s-expressions (SPEC.md section 5.1):
-- parentheses, double-quoted strings without escapes, @;@ line comments, and
-- atoms, which are either 64-bit integers or case-sensitive symbols.
module Spiremark.SExpr
  ( SExpr (..)
  , parseSExprs
  , render
  ) where

import Data.Char (isDigit)
import Data.Int (Int64)

-- | A parsed s-expression.
data SExpr
  = SInt !Integer     -- ^ an integer atom (guaranteed to fit in an @Int64@)
  | SSym String       -- ^ a symbol atom
  | SStr String       -- ^ a string literal (contents without the quotes)
  | SList [SExpr]     -- ^ a parenthesised list
  deriving (Eq, Show)

data Token = TOpen | TClose | TStr String | TAtom String

isWs :: Char -> Bool
isWs c = c `elem` " \t\r\n\f\v"

isAtomChar :: Char -> Bool
isAtomChar c = not (isWs c) && c `notElem` "();\""

tokenize :: String -> Maybe [Token]
tokenize [] = Just []
tokenize (c : cs)
  | isWs c = tokenize cs
  | c == ';' = tokenize (dropWhile (/= '\n') cs)
  | c == '(' = (TOpen :) <$> tokenize cs
  | c == ')' = (TClose :) <$> tokenize cs
  | c == '"' =
      let (body, rest) = break (\x -> x == '"' || x == '\n') cs
       in case rest of
            ('"' : rest') -> (TStr body :) <$> tokenize rest'
            _ -> Nothing
  | otherwise =
      let (a, rest) = span isAtomChar (c : cs)
       in (TAtom a :) <$> tokenize rest

isIntAtom :: String -> Bool
isIntAtom ('-' : ds) = not (null ds) && all isDigit ds
isIntAtom ds = not (null ds) && all isDigit ds

-- | Parse a whole file into top-level expressions.  'Nothing' means the text
-- does not tokenise, has unbalanced parentheses, or holds an integer atom
-- outside the signed 64-bit range.
parseSExprs :: String -> Maybe [SExpr]
parseSExprs src = do
  toks <- tokenize src
  go toks []
  where
    go [] acc = Just (reverse acc)
    go ts acc = do
      (e, rest) <- expr ts
      go rest (e : acc)
    expr (TOpen : ts) = list ts []
    expr (TClose : _) = Nothing
    expr (TStr s : ts) = Just (SStr s, ts)
    expr (TAtom a : ts)
      | isIntAtom a =
          let n = read a :: Integer
           in if n >= toInteger (minBound :: Int64) && n <= toInteger (maxBound :: Int64)
                then Just (SInt n, ts)
                else Nothing
      | otherwise = Just (SSym a, ts)
    expr [] = Nothing
    list (TClose : ts) acc = Just (SList (reverse acc), ts)
    list [] _ = Nothing
    list ts acc = do
      (e, rest) <- expr ts
      list rest (e : acc)

-- | Canonical printing: lists joined by single spaces, no other whitespace.
render :: SExpr -> String
render (SInt n) = show n
render (SSym s) = s
render (SStr s) = '"' : s ++ "\""
render (SList xs) = "(" ++ unwords (map render xs) ++ ")"
