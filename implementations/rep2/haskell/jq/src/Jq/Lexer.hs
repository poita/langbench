-- | Tokeniser for filter text.
module Jq.Lexer
  ( Token (..)
  , tokenize
  ) where

import qualified Data.ByteString.Char8 as BC
import Data.Char (chr, isAlpha, isAlphaNum, isDigit, isHexDigit, digitToInt)
import Data.Text (Text)
import qualified Data.Text as T

import Jq.Number (scanNumber)

data Token
  = TNum Double
  | TStr Text
  | TIdent Text      -- ^ identifiers and keywords
  | TVar Text        -- ^ @$name@
  | TSym String      -- ^ punctuation and operators
  deriving (Eq, Show)

-- | Split filter text into tokens.
tokenize :: String -> Either String [Token]
tokenize [] = Right []
tokenize s@(c : cs)
  | c == ' ' || c == '\t' || c == '\n' || c == '\r' = tokenize cs
  | isDigit c =
      let (ds, rest) = span isDigit s
          (frac, rest') = case rest of
            ('.' : d : more) | isDigit d -> let (f, r) = span isDigit (d : more) in ('.' : f, r)
            _ -> ("", rest)
          txt = ds ++ frac
      in case scanNumber (BC.pack txt) 0 of
           Just (d, _) -> (TNum d :) <$> tokenize rest'
           Nothing -> Left ("bad number " ++ txt)
  | isIdStart c = let (w, rest) = span isIdChar s in (TIdent (T.pack w) :) <$> tokenize rest
  | c == '$' = case span isIdChar cs of
      ([], _) -> Left "expected name after '$'"
      (w, rest) -> (TVar (T.pack w) :) <$> tokenize rest
  | c == '"' = do
      (str, rest) <- lexString cs
      (TStr (T.pack str) :) <$> tokenize rest
  | otherwise = case s of
      ('=' : '=' : r) -> sym "==" r
      ('!' : '=' : r) -> sym "!=" r
      ('<' : '=' : r) -> sym "<=" r
      ('>' : '=' : r) -> sym ">=" r
      _ | c `elem` (".,|()[]{}:;?+-*/%<>" :: String) -> sym [c] cs
        | otherwise -> Left ("unexpected character " ++ show c)
  where
    sym t r = (TSym t :) <$> tokenize r

isIdStart, isIdChar :: Char -> Bool
isIdStart c = (isAlpha c && c < '\x80') || c == '_'
isIdChar c = isIdStart c || (isAlphaNum c && c < '\x80')

-- | Lex a string body (after the opening quote); returns the decoded string
-- and the remaining input after the closing quote.
lexString :: String -> Either String (String, String)
lexString = go []
  where
    go acc [] = Left "unterminated string" <* pure acc
    go acc ('"' : r) = Right (reverse acc, r)
    go acc ('\\' : e : r) = case e of
      '"' -> go ('"' : acc) r
      '\\' -> go ('\\' : acc) r
      '/' -> go ('/' : acc) r
      'b' -> go ('\b' : acc) r
      'f' -> go ('\f' : acc) r
      'n' -> go ('\n' : acc) r
      'r' -> go ('\r' : acc) r
      't' -> go ('\t' : acc) r
      'u' -> case hex4 r of
        Nothing -> Left "bad \\u escape"
        Just (hi, r')
          | hi >= 0xD800 && hi < 0xDC00
          , ('\\' : 'u' : r'') <- r'
          , Just (lo, r3) <- hex4 r''
          , lo >= 0xDC00 && lo < 0xE000 ->
              go (chr (0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)) : acc) r3
          | hi >= 0xD800 && hi < 0xE000 -> go ('\xFFFD' : acc) r'
          | otherwise -> go (chr hi : acc) r'
      _ -> Left "bad escape"
    go acc (c : r) = go (c : acc) r
    hex4 r = case splitAt 4 r of
      (h, r') | length h == 4 && all isHexDigit h -> Just (foldl (\a d -> a * 16 + digitToInt d) 0 h, r')
      _ -> Nothing
