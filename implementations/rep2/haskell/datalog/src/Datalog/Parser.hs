-- |
-- Module      : Datalog.Parser
-- Description : Tokeniser and parser for Datalog source text.
module Datalog.Parser
  ( parseProgram
  , Token (..)
  , tokenize
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)

import Datalog.Syntax

-- | Lexical tokens.
data Token
  = TIdent String
  | TVariable String
  | TUnderscore
  | TInteger Int
  | TNot
  | TLParen
  | TRParen
  | TComma
  | TDot
  | TImplies   -- ^ @:-@
  | TQuery     -- ^ @?-@
  | TCompare CmpOp
  deriving (Eq, Show)

isIdentChar :: Char -> Bool
isIdentChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '_'

-- | Split source text into tokens (longest match; @%@ comments and
-- whitespace are skipped).
tokenize :: String -> Either String [Token]
tokenize [] = Right []
tokenize s@(c : cs)
  | c `elem` " \t\r\n" = tokenize cs
  | c == '%' = tokenize (dropWhile (/= '\n') cs)
  | c == '(' = (TLParen :) <$> tokenize cs
  | c == ')' = (TRParen :) <$> tokenize cs
  | c == ',' = (TComma :) <$> tokenize cs
  | c == '.' = (TDot :) <$> tokenize cs
  | c == ':', '-' : r <- cs = (TImplies :) <$> tokenize r
  | c == '?', '-' : r <- cs = (TQuery :) <$> tokenize r
  | c == '<', '=' : r <- cs = (TCompare OpLe :) <$> tokenize r
  | c == '<' = (TCompare OpLt :) <$> tokenize cs
  | c == '>', '=' : r <- cs = (TCompare OpGe :) <$> tokenize r
  | c == '>' = (TCompare OpGt :) <$> tokenize cs
  | c == '=' = (TCompare OpEq :) <$> tokenize cs
  | c == '!', '=' : r <- cs = (TCompare OpNe :) <$> tokenize r
  | c == '-', d : _ <- cs, isDigit d =
      let (ds, r) = span isDigit cs in (TInteger (negate (read ds)) :) <$> tokenize r
  | isDigit c =
      let (ds, r) = span isDigit s in (TInteger (read ds) :) <$> tokenize r
  | isAsciiLower c =
      let (w, r) = span isIdentChar s
          t = if w == "not" then TNot else TIdent w
      in (t :) <$> tokenize r
  | isAsciiUpper c =
      let (w, r) = span isIdentChar s in (TVariable w :) <$> tokenize r
  | c == '_' =
      let (_, r) = span isIdentChar s in (TUnderscore :) <$> tokenize r
  | otherwise = Left ("unexpected character " ++ show c)

type P a = [Token] -> Either String (a, [Token])

-- | Parse a whole program. Malformed input yields a 'Left' message.
parseProgram :: String -> Either String Program
parseProgram src = tokenize src >>= go [] []
  where
    go rs qs [] = Right (Program (reverse rs) (reverse qs))
    go rs qs (TQuery : ts) = do
      (a, ts') <- atomP ts
      ts'' <- expect TDot ts'
      go rs (a : qs) ts''
    go rs qs ts = do
      (h, ts') <- atomP ts
      case ts' of
        TDot : r -> go (Rule h [] : rs) qs r
        TImplies : r -> do
          (body, r') <- literals r
          go (Rule h body : rs) qs r'
        _ -> Left "expected '.' or ':-' after rule head"

    literals ts = do
      (l, ts') <- literalP ts
      case ts' of
        TComma : r -> do
          (ls, r') <- literals r
          Right (l : ls, r')
        TDot : r -> Right ([l], r)
        _ -> Left "expected ',' or '.' in rule body"

expect :: Token -> [Token] -> Either String [Token]
expect t (t' : ts) | t == t' = Right ts
expect t _ = Left ("expected " ++ show t)

literalP :: P Literal
literalP (TNot : ts) = do
  (a, r) <- atomP ts
  Right (Neg a, r)
literalP ts@(TIdent _ : TLParen : _) = do
  (a, r) <- atomP ts
  Right (Pos a, r)
literalP ts = do
  (l, r1) <- termP ts
  case r1 of
    TCompare op : r2 -> do
      (rt, r3) <- termP r2
      Right (Cmp op l rt, r3)
    _ -> Left "expected comparison operator"

atomP :: P Atom
atomP (TIdent n : TLParen : ts) = do
  (args, r) <- terms ts
  Right (Atom n args, r)
  where
    terms xs = do
      (t, r) <- termP xs
      case r of
        TComma : r' -> do
          (more, r'') <- terms r'
          Right (t : more, r'')
        TRParen : r' -> Right ([t], r')
        _ -> Left "expected ',' or ')' in argument list"
atomP _ = Left "expected atom"

termP :: P Term
termP (TInteger n : r) = Right (TConst (CInt n), r)
termP (TIdent s : r) = Right (TConst (CSym s), r)
termP (TVariable v : r) = Right (TVar v, r)
termP (TUnderscore : r) = Right (TAnon, r)
termP _ = Left "expected term"
