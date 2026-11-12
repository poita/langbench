-- | Recursive-descent parser for the source language (see @SPEC.md@ for the
-- grammar).
module Language.TypeInfer.Parser
  ( parseProgram
  , parseExpr
  ) where

import Language.TypeInfer.Error
import Language.TypeInfer.Lexer
import Language.TypeInfer.Syntax

-- | Parse a whole program: zero or more declarations, each ending in @;;@.
parseProgram :: String -> Either ParseError Program
parseProgram src = runParser (pDecls []) src

-- | Parse a single expression (without a trailing @;;@).
parseExpr :: String -> Either ParseError Expr
parseExpr = runParser (pExpr <* expectEOF)

------------------------------------------------------------------------------
-- Parser monad

newtype Parser a = Parser {unParser :: [Located] -> Either ParseError (a, [Located])}

instance Functor Parser where
  fmap f (Parser p) = Parser $ \ts -> case p ts of
    Left e -> Left e
    Right (a, ts') -> Right (f a, ts')

instance Applicative Parser where
  pure a = Parser $ \ts -> Right (a, ts)
  Parser pf <*> Parser pa = Parser $ \ts -> case pf ts of
    Left e -> Left e
    Right (f, ts') -> case pa ts' of
      Left e -> Left e
      Right (a, ts'') -> Right (f a, ts'')

instance Monad Parser where
  Parser p >>= f = Parser $ \ts -> case p ts of
    Left e -> Left e
    Right (a, ts') -> unParser (f a) ts'

runParser :: Parser a -> String -> Either ParseError a
runParser p src = do
  toks <- tokenize src
  (a, _) <- unParser p toks
  pure a

peek :: Parser Located
peek = Parser $ \case
  [] -> Left (ParseError (Pos 1 1) "unexpected end of input")
  ts@(t : _) -> Right (t, ts)

peekTok :: Parser Token
peekTok = locTok <$> peek

advance :: Parser ()
advance = Parser $ \case
  [] -> Right ((), [])
  [t] | locTok t == TokEOF -> Right ((), [t])
  _ : ts -> Right ((), ts)

failHere :: String -> Parser a
failHere msg = do
  Located pos tok <- peek
  Parser $ \_ -> Left (ParseError pos (msg ++ ", found " ++ describe tok))

describe :: Token -> String
describe = \case
  TokInt s -> "integer " ++ s
  TokIdent s -> "identifier " ++ s
  TokSym s -> show s
  TokEOF -> "end of input"
  t -> "keyword " ++ show t

expectSym :: String -> Parser ()
expectSym s = peekTok >>= \case
  TokSym s' | s' == s -> advance
  _ -> failHere ("expected " ++ show s)

expectTok :: Token -> String -> Parser ()
expectTok t what = peekTok >>= \t' ->
  if t' == t then advance else failHere ("expected " ++ what)

expectEOF :: Parser ()
expectEOF = peekTok >>= \case
  TokEOF -> pure ()
  _ -> failHere "expected end of input"

ident :: Parser Name
ident = peekTok >>= \case
  TokIdent x -> advance >> pure x
  _ -> failHere "expected identifier"

idents :: Parser [Name]
idents = go []
  where
    go acc = peekTok >>= \case
      TokIdent x -> advance >> go (x : acc)
      _ -> pure (reverse acc)

isSym :: String -> Token -> Bool
isSym s = (== TokSym s)

------------------------------------------------------------------------------
-- Declarations

pDecls :: [Decl] -> Parser Program
pDecls acc = peekTok >>= \case
  TokEOF -> pure (reverse acc)
  TokLet -> do
    advance
    b <- pBinding
    expectSym ";;"
    d <- case b of
      Binding False f ps rhs -> pure (DLet f (mkFuns ps rhs))
      Binding True f (p : ps) rhs -> pure (DLetRec f p (mkFuns ps rhs))
      Binding True _ [] _ -> failHere "'let rec' needs at least one parameter"
    pDecls (d : acc)
  _ -> do
    e <- pExpr
    expectSym ";;"
    pDecls (DExpr e : acc)

-- | The part of a @let@ between the keyword and the @in@ / @;;@.
data Binding = Binding Bool Name [Name] Expr

pBinding :: Parser Binding
pBinding = do
  isRec <- peekTok >>= \case
    TokRec -> advance >> pure True
    _ -> pure False
  f <- ident
  ps <- idents
  expectSym "="
  rhs <- pExpr
  pure (Binding isRec f ps rhs)

------------------------------------------------------------------------------
-- Expressions

pExpr :: Parser Expr
pExpr = peekTok >>= \case
  TokLet -> do
    advance
    Binding isRec f ps rhs <- pBinding
    expectTok TokIn "'in'"
    body <- pExpr
    case (isRec, ps) of
      (False, _) -> pure (ELet f (mkFuns ps rhs) body)
      (True, p : ps') -> pure (ELetRec f p (mkFuns ps' rhs) body)
      (True, []) -> failHere "'let rec' needs at least one parameter"
  TokFun -> do
    advance
    ps <- idents
    if null ps then failHere "expected parameter" else pure ()
    expectSym "->"
    mkFuns ps <$> pExpr
  TokIf -> do
    advance
    c <- pExpr
    expectTok TokThen "'then'"
    a <- pExpr
    expectTok TokElse "'else'"
    EIf c a <$> pExpr
  _ -> pOr

-- | Left-associative chain of binary operators.
chainL :: [(String, BinOp)] -> Parser Expr -> Parser Expr
chainL ops operand = operand >>= loop
  where
    loop l = peekTok >>= \case
      TokSym s | Just op <- lookup s ops -> do
        advance
        r <- operand
        loop (EBin op l r)
      _ -> pure l

pOr, pAnd, pCmp, pCons, pAdd, pMul, pApp, pAtom :: Parser Expr
pOr = chainL [("||", Or)] pAnd
pAnd = chainL [("&&", And)] pCmp
pCmp = do
  l <- pCons
  peekTok >>= \case
    TokSym s | Just op <- lookup s cmpOps -> do
      advance
      EBin op l <$> pCons
    _ -> pure l
  where
    cmpOps = [("=", Eq), ("<", Lt), (">", Gt), ("<=", Le), (">=", Ge)]
pCons = do
  l <- pAdd
  peekTok >>= \case
    TokSym "::" -> advance >> ECons l <$> pCons
    _ -> pure l
pAdd = chainL [("+", Add), ("-", Sub)] pMul
pMul = chainL [("*", Mul), ("/", Div)] pApp

pApp = pAtom >>= loop
  where
    loop f = peekTok >>= \t ->
      if startsAtom t then pAtom >>= \a -> loop (EApp f a) else pure f

startsAtom :: Token -> Bool
startsAtom = \case
  TokInt _ -> True
  TokIdent _ -> True
  TokTrue -> True
  TokFalse -> True
  TokSym "(" -> True
  TokSym "[" -> True
  _ -> False

pAtom = peekTok >>= \case
  TokInt ds -> advance >> pure (ELit (LInt ds))
  TokTrue -> advance >> pure (ELit (LBool True))
  TokFalse -> advance >> pure (ELit (LBool False))
  TokIdent x -> advance >> pure (EVar x)
  TokSym "(" -> do
    advance
    peekTok >>= \case
      TokSym ")" -> advance >> pure (ELit LUnit)
      _ -> do
        e <- pExpr
        peekTok >>= \case
          TokSym ")" -> advance >> pure e
          TokSym "," -> do
            es <- sepBy1 "," pExpr
            expectSym ")"
            pure (ETuple (e : es))
          _ -> failHere "expected ')' or ','"
  TokSym "[" -> do
    advance
    peekTok >>= \case
      TokSym "]" -> advance >> pure (EList [])
      _ -> do
        e <- pExpr
        es <- sepBy ";" pExpr
        expectSym "]"
        pure (EList (e : es))
  _ -> failHere "expected expression"

-- | Zero or more @sep p@ items.
sepBy :: String -> Parser a -> Parser [a]
sepBy sep p = go []
  where
    go acc = peekTok >>= \t ->
      if isSym sep t then advance >> p >>= \x -> go (x : acc) else pure (reverse acc)

-- | One or more @sep p@ items (the first separator is required).
sepBy1 :: String -> Parser a -> Parser [a]
sepBy1 sep p = do
  expectSym sep
  x <- p
  (x :) <$> sepBy sep p
