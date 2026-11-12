-- |
-- Module      : Scheme.Reader
-- Description : Recursive-descent reader turning text into datums.
module Scheme.Reader
  ( readDatum
  , readAll
  ) where

import Control.Exception (throwIO)
import Data.Char (isDigit)

import qualified Scheme.BigInt as B
import Scheme.Types

-- | Read the next datum from the text, returning it with the remaining
-- input, or 'Nothing' if only whitespace and comments remain.  Malformed
-- input throws a 'SyntaxError'.
readDatum :: SymbolTable -> String -> IO (Maybe (Value, String))
readDatum tbl s0 = case skipBlank s0 of
  [] -> pure Nothing
  s -> Just <$> datum tbl s

-- | Read every datum in the text.
readAll :: SymbolTable -> String -> IO [Value]
readAll tbl = go
  where
    go s = readDatum tbl s >>= maybe (pure []) (\(v, rest) -> (v :) <$> go rest)

syntaxError :: String -> IO a
syntaxError = throwIO . SyntaxError

isSpace' :: Char -> Bool
isSpace' c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

isDelimiter :: Char -> Bool
isDelimiter c = isSpace' c || c `elem` "()'\";"

-- | Skip whitespace and @;@ comments.
skipBlank :: String -> String
skipBlank [] = []
skipBlank (c : cs)
  | isSpace' c = skipBlank cs
  | c == ';' = skipBlank (dropWhile (/= '\n') cs)
  | otherwise = c : cs

-- | Read one datum from non-blank input.
datum :: SymbolTable -> String -> IO (Value, String)
datum _ [] = syntaxError "unexpected end of input"
datum tbl (c : cs) = case c of
  '(' -> list tbl cs
  ')' -> syntaxError "unexpected )"
  '\'' -> case skipBlank cs of
    [] -> syntaxError "unexpected end of input after '"
    rest -> do
      (d, rest') <- datum tbl rest
      q <- VSym <$> intern tbl "quote"
      inner <- cons d VNil
      v <- cons q inner
      pure (v, rest')
  '"' -> string cs
  _ -> do
    let (tok, rest) = break isDelimiter (c : cs)
    v <- atom tbl tok
    pure (v, rest)

atom :: SymbolTable -> String -> IO Value
atom tbl tok = case tok of
  "#t" -> pure (VBool True)
  "#f" -> pure (VBool False)
  _ | isIntegerToken tok, Just n <- B.fromDecimal tok -> pure (VInt n)
    | otherwise -> VSym <$> intern tbl tok

isIntegerToken :: String -> Bool
isIntegerToken tok = case tok of
  '+' : ds -> digits ds
  '-' : ds -> digits ds
  ds -> digits ds
  where digits ds = not (null ds) && all isDigit ds

string :: String -> IO (Value, String)
string = go []
  where
    go _ [] = syntaxError "unterminated string"
    go acc ('"' : rest) = pure (VStr (reverse acc), rest)
    go acc ('\\' : e : rest) = go (esc e : acc) rest
    go acc (c : rest) = go (c : acc) rest
    esc 'n' = '\n'
    esc 't' = '\t'
    esc c = c

-- | Read list elements after the opening parenthesis.
list :: SymbolTable -> String -> IO (Value, String)
list tbl = go []
  where
    go acc s = case skipBlank s of
      [] -> syntaxError "unterminated list"
      ')' : rest -> do
        v <- build acc VNil
        pure (v, rest)
      '.' : rest@(r : _) | isDelimiter r -> do
        (t, rest') <- datum tbl =<< nonBlank rest
        case skipBlank rest' of
          ')' : rest'' -> do
            v <- build acc t
            pure (v, rest'')
          _ -> syntaxError "expected ) after dotted tail"
      s' -> do
        (d, rest) <- datum tbl s'
        go (d : acc) rest
    nonBlank s = case skipBlank s of
      [] -> syntaxError "unexpected end of input"
      s' -> pure s'
    -- acc is in reverse order
    build [] tl = pure tl
    build (x : xs) tl = cons x tl >>= build xs
