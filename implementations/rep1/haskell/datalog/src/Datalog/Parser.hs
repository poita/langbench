-- |
-- Module      : Datalog.Parser
-- Description : Lexer and recursive-descent parser for Datalog source text.
--
-- Implements the grammar of the specification. Whitespace and @%@ comments
-- may appear between any two tokens. Only well-formed programs are
-- guaranteed to parse; malformed input yields a 'ParseError'.
module Datalog.Parser
  ( ParseError (..)
  , parseProgram
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlphaNum, isDigit, isLower, isSpace, isUpper)

import Datalog.Syntax

-- | A lexical or syntactic error, with a human-readable description.
newtype ParseError = ParseError String
  deriving (Eq, Show)

data Token
  = TIdent !ByteString
  | TVarName !ByteString
  | TUnderscore
  | TNumber !Int
  | TNot
  | TLParen
  | TRParen
  | TComma
  | TDot
  | TImplies
  | TQueryMark
  | TCmp !CmpOp
  deriving (Eq, Show)

-- | Parse a whole program.
--
-- >>> parseProgram (B.pack "p(a). ?- p(X).")
-- Right [ClauseRule (Rule {ruleHead = Atom {atomPred = "p", atomArgs = [TConst (CSym "a")]}, ruleBody = []}),ClauseQuery (Atom {atomPred = "p", atomArgs = [TVar "X"]})]
parseProgram :: ByteString -> Either ParseError Program
parseProgram src = tokenize src >>= clauses

------------------------------------------------------------------------------
-- Lexer

tokenize :: ByteString -> Either ParseError [Token]
tokenize s0 = go s0
  where
    go s = case B.uncons s of
      Nothing -> Right []
      Just (c, rest)
        | isSpace c -> go (B.dropWhile isSpace rest)
        | c == '%' -> go (B.dropWhile (/= '\n') rest)
        | c == '(' -> (TLParen :) <$> go rest
        | c == ')' -> (TRParen :) <$> go rest
        | c == ',' -> (TComma :) <$> go rest
        | c == '.' -> (TDot :) <$> go rest
        | c == ':', Just ('-', r) <- B.uncons rest -> (TImplies :) <$> go r
        | c == '?', Just ('-', r) <- B.uncons rest -> (TQueryMark :) <$> go r
        | c == '<' -> case B.uncons rest of
            Just ('=', r) -> (TCmp OpLe :) <$> go r
            _ -> (TCmp OpLt :) <$> go rest
        | c == '>' -> case B.uncons rest of
            Just ('=', r) -> (TCmp OpGe :) <$> go r
            _ -> (TCmp OpGt :) <$> go rest
        | c == '=' -> (TCmp OpEq :) <$> go rest
        | c == '!', Just ('=', r) <- B.uncons rest -> (TCmp OpNe :) <$> go r
        | c == '-', Just (d, _) <- B.uncons rest, isDigit d -> number True rest
        | isDigit c -> number False s
        | isLower c ->
            let (name, r) = B.span identChar s
                tok = if name == B.pack "not" then TNot else TIdent name
             in (tok :) <$> go r
        | isUpper c ->
            let (name, r) = B.span identChar s
             in (TVarName name :) <$> go r
        | c == '_' ->
            let (name, r) = B.span identChar s
             in if B.length name == 1
                  then (TUnderscore :) <$> go r
                  else (TVarName name :) <$> go r
        | otherwise -> Left (ParseError ("unexpected character " ++ show c))

    number neg s = case B.readInt s of
      Just (n, r) -> ((TNumber (if neg then negate n else n)) :) <$> go r
      Nothing -> Left (ParseError "bad integer")

    identChar ch = isAlphaNum ch || ch == '_'

------------------------------------------------------------------------------
-- Parser

type P a = [Token] -> Either ParseError (a, [Token])

failP :: String -> [Token] -> Either ParseError a
failP msg ts = Left (ParseError (msg ++ " near " ++ show (take 3 ts)))

clauses :: [Token] -> Either ParseError Program
clauses [] = Right []
clauses (TQueryMark : ts) = do
  (a, ts1) <- atom ts
  ts2 <- expect TDot ts1
  (ClauseQuery a :) <$> clauses ts2
clauses ts = do
  (h, ts1) <- atom ts
  case ts1 of
    TDot : ts2 -> (ClauseRule (Rule h []) :) <$> clauses ts2
    TImplies : ts2 -> do
      (body, ts3) <- literals ts2
      ts4 <- expect TDot ts3
      (ClauseRule (Rule h body) :) <$> clauses ts4
    _ -> failP "expected '.' or ':-'" ts1

expect :: Token -> [Token] -> Either ParseError [Token]
expect t (t' : ts) | t == t' = Right ts
expect t ts = failP ("expected " ++ show t) ts

literals :: P [Literal]
literals ts = do
  (l, ts1) <- literal ts
  case ts1 of
    TComma : ts2 -> do
      (ls, ts3) <- literals ts2
      Right (l : ls, ts3)
    _ -> Right ([l], ts1)

literal :: P Literal
literal (TNot : ts) = do
  (a, ts1) <- atom ts
  Right (Neg a, ts1)
literal ts@(TIdent _ : TLParen : _) = do
  (a, ts1) <- atom ts
  Right (Pos a, ts1)
literal ts = do
  (l, ts1) <- term ts
  case ts1 of
    TCmp op : ts2 -> do
      (r, ts3) <- term ts2
      Right (Cmp op l r, ts3)
    _ -> failP "expected comparison operator" ts1

atom :: P Atom
atom (TIdent p : TLParen : ts) = do
  (args, ts1) <- terms ts
  ts2 <- expect TRParen ts1
  Right (Atom p args, ts2)
atom ts = failP "expected atom" ts

terms :: P [Term]
terms ts = do
  (t, ts1) <- term ts
  case ts1 of
    TComma : ts2 -> do
      (rest, ts3) <- terms ts2
      Right (t : rest, ts3)
    _ -> Right ([t], ts1)

term :: P Term
term (TIdent s : ts) = Right (TConst (CSym s), ts)
term (TNumber n : ts) = Right (TConst (CInt n), ts)
term (TVarName v : ts) = Right (TVar v, ts)
term (TUnderscore : ts) = Right (TAnon, ts)
term ts = failP "expected term" ts
