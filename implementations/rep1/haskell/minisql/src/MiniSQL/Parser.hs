{-# LANGUAGE OverloadedStrings #-}

-- | Recursive-descent parser for one statement.
module MiniSQL.Parser
  ( parseStatement
  , parseScript
  , parseExpr
  ) where

import Control.Monad (when)
import Data.Text (Text)

import MiniSQL.Error
import MiniSQL.Lexer
import MiniSQL.Syntax

-- | Parse a whole script into one result per non-empty statement.
parseScript :: Text -> [Either Error Statement]
parseScript = map parseStatement . splitStatements . tokenize

-- | Parse the tokens of a single statement (without its @;@).
parseStatement :: [Token] -> Either Error Statement
parseStatement = runAll statement

-- | Parse a standalone expression from source text.
parseExpr :: Text -> Either Error Expr
parseExpr = runAll expr . tokenize

runAll :: Parser a -> [Token] -> Either Error a
runAll p ts = do
  (a, rest) <- unParser p ts
  case rest of
    [] -> Right a
    (t : _) -> Left (SyntaxError ("unexpected " ++ show t))

------------------------------------------------------------------------------
-- Parser monad

newtype Parser a = Parser {unParser :: [Token] -> Either Error (a, [Token])}

instance Functor Parser where
  fmap f (Parser p) = Parser $ \ts -> case p ts of
    Left e -> Left e
    Right (a, r) -> Right (f a, r)

instance Applicative Parser where
  pure a = Parser $ \ts -> Right (a, ts)
  Parser pf <*> Parser pa = Parser $ \ts -> case pf ts of
    Left e -> Left e
    Right (f, r) -> case pa r of
      Left e -> Left e
      Right (a, r') -> Right (f a, r')

instance Monad Parser where
  Parser p >>= f = Parser $ \ts -> case p ts of
    Left e -> Left e
    Right (a, r) -> unParser (f a) r

failP :: String -> Parser a
failP msg = Parser $ \_ -> Left (SyntaxError msg)

peek :: Parser (Maybe Token)
peek = Parser $ \ts -> Right (case ts of [] -> Nothing; (t : _) -> Just t, ts)

-- | Number of tokens left; used to tell how many tokens a parser consumed.
remaining :: Parser Int
remaining = Parser $ \ts -> Right (length ts, ts)

advance :: Parser ()
advance = Parser $ \ts -> case ts of
  [] -> Left (SyntaxError "unexpected end of statement")
  (_ : r) -> Right ((), r)

next :: Parser Token
next = Parser $ \ts -> case ts of
  [] -> Left (SyntaxError "unexpected end of statement")
  (t : r) -> Right (t, r)

expect :: Token -> Parser ()
expect t = do
  t' <- peek
  if t' == Just t then advance else failP ("expected " ++ show t ++ ", found " ++ maybe "end of statement" show t')

expectKw :: Keyword -> Parser ()
expectKw = expect . TKeyword

-- | Consume the token if it is next.
accept :: Token -> Parser Bool
accept t = do
  t' <- peek
  if t' == Just t then advance >> pure True else pure False

ident :: Parser Text
ident = do
  t <- next
  case t of
    TIdent n -> pure n
    _ -> failP ("expected a name, found " ++ show t)

sepBy1 :: Parser a -> Parser [a]
sepBy1 p = do
  a <- p
  more <- accept TComma
  if more then (a :) <$> sepBy1 p else pure [a]

------------------------------------------------------------------------------
-- Statements

statement :: Parser Statement
statement = do
  t <- next
  case t of
    TKeyword KCreate -> createTable
    TKeyword KInsert -> insert
    TKeyword KDelete -> delete
    TKeyword KUpdate -> update
    TKeyword KSelect -> SelectStmt <$> select
    _ -> failP ("unsupported statement starting with " ++ show t)

createTable :: Parser Statement
createTable = do
  expectKw KTable
  name <- ident
  expect TLParen
  cols <- sepBy1 column
  expect TRParen
  pure (CreateTable name cols)
  where
    column = do
      n <- ident
      t <- next
      case t of
        TKeyword KInteger -> pure (n, TypeInteger)
        TKeyword KText -> pure (n, TypeText)
        _ -> failP "expected INTEGER or TEXT"

insert :: Parser Statement
insert = do
  expectKw KInto
  name <- ident
  expectKw KValues
  Insert name <$> sepBy1 tuple
  where
    tuple = expect TLParen *> sepBy1 expr <* expect TRParen

delete :: Parser Statement
delete = do
  expectKw KFrom
  name <- ident
  Delete name <$> optionalWhere

update :: Parser Statement
update = do
  name <- ident
  expectKw KSet
  sets <- sepBy1 assignment
  Update name sets <$> optionalWhere
  where
    assignment = do
      c <- ident
      expect TEq
      e <- expr
      pure (c, e)

optionalWhere :: Parser (Maybe Expr)
optionalWhere = do
  w <- accept (TKeyword KWhere)
  if w then Just <$> expr else pure Nothing

select :: Parser Select
select = do
  items <- sepBy1 selectItem
  (from, on) <- fromClause
  wh <- optionalWhere
  grp <- do
    g <- accept (TKeyword KGroup)
    if g then expectKw KBy *> sepBy1 columnRef else pure []
  hav <- do
    h <- accept (TKeyword KHaving)
    if h then Just <$> expr else pure Nothing
  when (null grp && hav /= Nothing) (failP "HAVING requires GROUP BY")
  ord' <- do
    o <- accept (TKeyword KOrder)
    if o then expectKw KBy *> sepBy1 orderTerm else pure []
  (lim, off) <- do
    l <- accept (TKeyword KLimit)
    if not l
      then pure (Nothing, Nothing)
      else do
        n <- natural
        o <- accept (TKeyword KOffset)
        m <- if o then Just <$> natural else pure Nothing
        pure (Just n, m)
  pure (Select items from on wh grp hav ord' lim off)

natural :: Parser Int
natural = do
  t <- next
  case t of
    TInt n -> pure (fromInteger n)
    _ -> failP "expected a non-negative integer"

selectItem :: Parser SelectItem
selectItem = do
  t <- peek
  case t of
    Just TStar -> advance >> pure Star
    _ -> do
      e <- expr
      t' <- peek
      case t' of
        Just (TKeyword KAs) -> advance >> (Item e . Just <$> ident)
        Just (TIdent n) -> advance >> pure (Item e (Just n))
        _ -> pure (Item e Nothing)

fromClause :: Parser ([TableRef], Maybe Expr)
fromClause = do
  f <- accept (TKeyword KFrom)
  if not f
    then pure ([], Nothing)
    else do
      a <- tableRef
      t <- peek
      case t of
        Just TComma -> do
          advance
          b <- tableRef
          pure ([a, b], Nothing)
        Just (TKeyword KInner) -> advance >> expectKw KJoin >> join' a
        Just (TKeyword KJoin) -> advance >> join' a
        _ -> pure ([a], Nothing)
  where
    join' a = do
      b <- tableRef
      expectKw KOn
      e <- expr
      pure ([a, b], Just e)

tableRef :: Parser TableRef
tableRef = do
  n <- ident
  t <- peek
  case t of
    Just (TKeyword KAs) -> advance >> (TableRef n . Just <$> ident)
    Just (TIdent a) -> advance >> pure (TableRef n (Just a))
    _ -> pure (TableRef n Nothing)

columnRef :: Parser ColumnRef
columnRef = do
  n <- ident
  d <- accept TDot
  if d then ColumnRef (Just n) <$> ident else pure (ColumnRef Nothing n)

orderTerm :: Parser OrderTerm
orderTerm = do
  before <- remaining
  t <- peek
  e <- expr
  after <- remaining
  let key = case (before - after, t, e) of
        (1, Just (TInt _), EInt k) -> OrdOrdinal k
        (1, Just (TIdent _), ECol Nothing n) -> OrdName n
        _ -> OrdExpr e
  d <- peek
  desc <- case d of
    Just (TKeyword KAsc) -> advance >> pure False
    Just (TKeyword KDesc) -> advance >> pure True
    _ -> pure False
  pure (OrderTerm key desc)

------------------------------------------------------------------------------
-- Expressions

expr :: Parser Expr
expr = chain andE [(TKeyword KOr, EOr)]

andE :: Parser Expr
andE = chain notE [(TKeyword KAnd, EAnd)]

notE :: Parser Expr
notE = do
  n <- accept (TKeyword KNot)
  if n then ENot <$> notE else eqE

eqE :: Parser Expr
eqE = relE >>= loop
  where
    loop l = do
      t <- peek
      case t of
        Just TEq -> binary Eq l
        Just TNe -> binary Ne l
        Just (TKeyword KIs) -> do
          advance
          neg <- accept (TKeyword KNot)
          expectKw KNull
          loop (if neg then ENot (EIsNull l) else EIsNull l)
        Just (TKeyword KLike) -> advance >> relE >>= loop . ELike l
        Just (TKeyword KNot) -> do
          advance
          expectKw KLike
          r <- relE
          loop (ENot (ELike l r))
        _ -> pure l
    binary op l = advance >> relE >>= loop . ECmp op l

relE :: Parser Expr
relE =
  chain
    addE
    [ (TLt, ECmp Lt), (TLe, ECmp Le), (TGt, ECmp Gt), (TGe, ECmp Ge) ]

addE :: Parser Expr
addE = chain mulE [(TPlus, EArith Add), (TMinus, EArith Sub)]

mulE :: Parser Expr
mulE = chain unary [(TStar, EArith Mul), (TSlash, EArith Div), (TPercent, EArith Mod)]

-- | Left-associative chain of binary operators.
chain :: Parser Expr -> [(Token, Expr -> Expr -> Expr)] -> Parser Expr
chain operand ops = operand >>= loop
  where
    loop l = do
      t <- peek
      case t >>= \tok -> lookup tok ops of
        Just f -> advance >> operand >>= loop . f l
        Nothing -> pure l

unary :: Parser Expr
unary = do
  m <- accept TMinus
  if m then ENeg <$> unary else primary

primary :: Parser Expr
primary = do
  t <- next
  case t of
    TInt n -> pure (EInt (fromInteger n))
    TString s -> pure (EStr s)
    TKeyword KNull -> pure ENull
    TLParen -> expr <* expect TRParen
    TIdent n -> do
      t' <- peek
      case t' of
        Just TLParen -> do
          fn <- maybe (failP ("unknown function " ++ show n)) pure (lookup n aggregates)
          advance
          call fn
        Just TDot -> do
          advance
          ECol (Just n) <$> ident
        _ -> pure (ECol Nothing n)
    _ -> failP ("unexpected " ++ show t ++ " in expression")
  where
    aggregates = [("count", Count), ("sum", Sum), ("min", Min), ("max", Max), ("avg", Avg)]
    call fn = do
      t <- peek
      case (fn, t) of
        (Count, Just TStar) -> advance >> expect TRParen >> pure (EAgg Count Nothing)
        _ -> do
          e <- expr
          expect TRParen
          pure (EAgg fn (Just e))
