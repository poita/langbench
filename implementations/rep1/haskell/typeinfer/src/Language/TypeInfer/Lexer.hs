-- | Tokeniser for the source language.
module Language.TypeInfer.Lexer
  ( Token (..)
  , Located (..)
  , tokenize
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)

import Language.TypeInfer.Error

-- | Lexical tokens.
data Token
  = TokInt String
  | TokIdent String
  | TokLet | TokRec | TokIn | TokFun | TokIf | TokThen | TokElse | TokTrue | TokFalse
  | TokSym String
    -- ^ Punctuation and operators: @;; -> :: <= >= && || ( ) [ ] ; , + - * / = < >@
  | TokEOF
  deriving (Eq, Show)

-- | A token with the position where it starts.
data Located = Located
  { locPos :: !Pos
  , locTok :: !Token
  }
  deriving (Eq, Show)

-- | Split source text into tokens. The result always ends with 'TokEOF'.
tokenize :: String -> Either ParseError [Located]
tokenize = go (Pos 1 1) []
  where
    go pos acc s = case s of
      [] -> Right (reverse (Located pos TokEOF : acc))
      c : cs
        | c == '\n' -> go (Pos (posLine pos + 1) 1) acc cs
        | c `elem` " \t\r" -> go (adv pos 1) acc cs
        | isDigit c ->
            let (ds, rest) = span isDigit s
            in emit pos acc (TokInt ds) (length ds) rest
        | isAsciiLower c ->
            let (w, rest) = span isIdentChar s
            in emit pos acc (wordToken w) (length w) rest
        | (a : b : rest) <- s, [a, b] `elem` twoChar ->
            emit pos acc (TokSym [a, b]) 2 rest
        | c `elem` oneChar -> emit pos acc (TokSym [c]) 1 cs
        | otherwise -> Left (ParseError pos ("unexpected character " ++ show c))

    emit pos acc tok n rest = go (adv pos n) (Located pos tok : acc) rest
    adv (Pos l c) n = Pos l (c + n)

    twoChar = [";;", "->", "::", "<=", ">=", "&&", "||"]
    oneChar = "()[];,+-*/=<>"

isIdentChar :: Char -> Bool
isIdentChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '_'

wordToken :: String -> Token
wordToken = \case
  "let" -> TokLet
  "rec" -> TokRec
  "in" -> TokIn
  "fun" -> TokFun
  "if" -> TokIf
  "then" -> TokThen
  "else" -> TokElse
  "true" -> TokTrue
  "false" -> TokFalse
  w -> TokIdent w
