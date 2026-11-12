-- | Tokeniser for filters.
module Jq.Lexer
  ( Token (..)
  , tokenize
  ) where

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Jq.Json.Parse (parseJson)
import Jq.Number (decimalToDouble)
import Jq.Value

-- | A lexical token.
data Token
  = TNum Double
  | TStr T.Text
  | TIdent String
  | TField T.Text -- ^ @.name@ or @."name"@ written without a space
  | TVar String -- ^ @$name@
  | TSym String -- ^ operators and punctuation
  deriving (Eq, Show)

-- | Split a filter into tokens.
tokenize :: String -> Either String [Token]
tokenize [] = Right []
tokenize s@(c : cs)
  | isSpace c = tokenize cs
  | c == '"' = do
      (t, rest) <- lexString s
      (TStr t :) <$> tokenize rest
  | c == '.', (n : _) <- cs, isIdentStart n =
      let (name, rest) = span isIdentChar cs in (TField (T.pack name) :) <$> tokenize rest
  | c == '.', ('"' : _) <- cs = do
      (t, rest) <- lexString cs
      (TField t :) <$> tokenize rest
  | isDigit c =
      let (ip, r1) = span isDigit s
          (fp, r2) = case r1 of
            ('.' : d : more) | isDigit d -> let (f, r) = span isDigit (d : more) in (f, r)
            _ -> ("", r1)
          m = read (ip ++ fp) :: Integer
       in (TNum (decimalToDouble m (negate (length fp))) :) <$> tokenize r2
  | isIdentStart c =
      let (name, rest) = span isIdentChar s in (TIdent name :) <$> tokenize rest
  | c == '$', (n : _) <- cs, isIdentStart n =
      let (name, rest) = span isIdentChar cs in (TVar name :) <$> tokenize rest
  | (a : b : rest) <- s, [a, b] `elem` (["==", "!=", "<=", ">="] :: [String]) = (TSym [a, b] :) <$> tokenize rest
  | c `elem` (".|,()[]{}:;?+-*/%<>" :: String) = (TSym [c] :) <$> tokenize cs
  | otherwise = Left ("unexpected character " ++ show c)

isIdentStart :: Char -> Bool
isIdentStart c = (isAlpha c && c < '\128') || c == '_'

isIdentChar :: Char -> Bool
isIdentChar c = isIdentStart c || (isAlphaNum c && c < '\128')

-- | Lex a string literal starting at its opening quote, decoding the JSON
-- escapes with the JSON parser.
lexString :: String -> Either String (T.Text, String)
lexString s = go (drop 1 s) (1 :: Int)
  where
    go [] _ = Left "unterminated string literal"
    go ('\\' : _ : r) n = go r (n + 2)
    go ('"' : r) n =
      let lit = take (n + 1) s
       in case parseJson (TE.encodeUtf8 (T.pack lit)) of
            Right (VString t) -> Right (t, r)
            _ -> Left "bad string literal"
    go (_ : r) n = go r (n + 1)
