-- | Recursive-descent parser for the filter grammar.
module Jq.Parser
  ( parseFilter
  ) where

import qualified Data.Text as T
import Data.Text (Text)

import Jq.Lexer
import Jq.Syntax
import Jq.Value

newtype P a = P { runP :: [Token] -> Either String (a, [Token]) }

instance Functor P where
  fmap f (P p) = P $ \ts -> case p ts of
    Left e -> Left e
    Right (a, r) -> Right (f a, r)

instance Applicative P where
  pure a = P $ \ts -> Right (a, ts)
  P pf <*> P pa = P $ \ts -> case pf ts of
    Left e -> Left e
    Right (f, r) -> case pa r of
      Left e -> Left e
      Right (a, r') -> Right (f a, r')

instance Monad P where
  P p >>= f = P $ \ts -> case p ts of
    Left e -> Left e
    Right (a, r) -> runP (f a) r

failP :: String -> P a
failP msg = P $ \ts -> Left (msg ++ " near " ++ show (take 3 ts))

peek :: P (Maybe Token)
peek = P $ \ts -> Right (case ts of [] -> Nothing; (t : _) -> Just t, ts)

peek2 :: P (Maybe Token)
peek2 = P $ \ts -> Right (case ts of (_ : t : _) -> Just t; _ -> Nothing, ts)

advance :: P ()
advance = P $ \ts -> Right ((), drop 1 ts)

sym :: String -> P Bool
sym s = do
  t <- peek
  if t == Just (TSym s) then advance >> pure True else pure False

expectSym :: String -> P ()
expectSym s = do
  ok <- sym s
  if ok then pure () else failP ("expected " ++ show s)

kw :: Text -> P Bool
kw s = do
  t <- peek
  if t == Just (TIdent s) then advance >> pure True else pure False

expectKw :: Text -> P ()
expectKw s = do
  ok <- kw s
  if ok then pure () else failP ("expected " ++ T.unpack s)

isKeyword :: Text -> Bool
isKeyword w = w `elem` ["if", "then", "elif", "else", "end", "as", "reduce", "and", "or"]

-- | Parse a filter. The whole input must be consumed.
parseFilter :: Text -> Either String Expr
parseFilter txt = do
  ts <- tokenize (T.unpack txt)
  (e, rest) <- runP pipe ts
  case rest of
    [] -> Right e
    (t : _) -> Left ("unexpected token " ++ show t)

pipe :: P Expr
pipe = do
  e <- comma
  isAs <- kw "as"
  if isAs
    then do
      t <- peek
      case t of
        Just (TVar x) -> do
          advance
          expectSym "|"
          Bind e x <$> pipe
        _ -> failP "expected variable after 'as'"
    else do
      bar <- sym "|"
      if bar then Pipe e <$> pipe else pure e

leftAssoc :: P Expr -> P (Maybe (Expr -> Expr -> Expr)) -> P Expr
leftAssoc operand opP = operand >>= go
  where
    go l = do
      m <- opP
      case m of
        Nothing -> pure l
        Just f -> operand >>= \r -> go (f l r)

comma :: P Expr
comma = leftAssoc orE (fmap (const Comma) <$> optional' (sym ","))

orE :: P Expr
orE = leftAssoc andE (fmap (const Or) <$> optional' (kw "or"))

andE :: P Expr
andE = leftAssoc cmp (fmap (const And) <$> optional' (kw "and"))

-- | Turn a "did it match" parser into one that yields 'Just' on a match.
optional' :: P Bool -> P (Maybe ())
optional' p = (\b -> if b then Just () else Nothing) <$> p

cmp :: P Expr
cmp = do
  l <- add
  t <- peek
  let op = case t of
        Just (TSym "==") -> Just Eq
        Just (TSym "!=") -> Just Ne
        Just (TSym "<") -> Just Lt
        Just (TSym "<=") -> Just Le
        Just (TSym ">") -> Just Gt
        Just (TSym ">=") -> Just Ge
        _ -> Nothing
  case op of
    Nothing -> pure l
    Just o -> advance >> Binop o l <$> add

add :: P Expr
add = leftAssoc mul $ do
  t <- peek
  case t of
    Just (TSym "+") -> advance >> pure (Just (Binop Add))
    Just (TSym "-") -> advance >> pure (Just (Binop Sub))
    _ -> pure Nothing

mul :: P Expr
mul = leftAssoc unary $ do
  t <- peek
  case t of
    Just (TSym "*") -> advance >> pure (Just (Binop Mul))
    Just (TSym "/") -> advance >> pure (Just (Binop Div))
    Just (TSym "%") -> advance >> pure (Just (Binop Mod))
    _ -> pure Nothing

unary :: P Expr
unary = do
  m <- sym "-"
  if m then Neg <$> unary else postfix

-- | A primary term followed by suffixes. The 'Bool' tracks whether the last
-- construct is a path operation that a following @?@ makes tolerant.
postfix :: P Expr
postfix = do
  (e, pending) <- primary
  suffixes e pending

suffixes :: Expr -> Bool -> P Expr
suffixes e pending = do
  t <- peek
  case t of
    Just (TSym "?") -> do
      advance
      if pending then suffixes (markOpt e) False else suffixes (Try e) False
    Just (TSym ".") -> do
      t2 <- peek2
      case t2 of
        Just (TIdent k) | not (isKeyword k) -> advance >> advance >> suffixes (Index e (str k) False) True
        Just (TStr k) -> advance >> advance >> suffixes (Index e (str k) False) True
        Just (TSym "[") -> advance >> suffixes e pending
        _ -> pure e
    Just (TSym "[") -> do
      advance
      e' <- bracket e
      suffixes e' True
    _ -> pure e
  where str = Literal . VStr

markOpt :: Expr -> Expr
markOpt e = case e of
  Index t k _ -> Index t k True
  Iterate t _ -> Iterate t True
  Slice t a b _ -> Slice t a b True
  _ -> Try e

-- | After an opening @[@ in suffix position.
bracket :: Expr -> P Expr
bracket t = do
  close <- sym "]"
  if close then pure (Iterate t False) else do
    colon <- sym ":"
    if colon
      then do
        hi <- pipe
        expectSym "]"
        pure (Slice t Nothing (Just hi) False)
      else do
        a <- pipe
        colon2 <- sym ":"
        if colon2
          then do
            close2 <- sym "]"
            if close2 then pure (Slice t (Just a) Nothing False) else do
              b <- pipe
              expectSym "]"
              pure (Slice t (Just a) (Just b) False)
          else expectSym "]" >> pure (Index t a False)

primary :: P (Expr, Bool)
primary = do
  mt <- peek
  case mt of
    Nothing -> failP "unexpected end of filter"
    Just t -> case t of
      TSym "." -> do
        advance
        t2 <- peek
        case t2 of
          Just (TIdent k) | not (isKeyword k) -> advance >> pure (Index Identity (Literal (VStr k)) False, True)
          Just (TStr k) -> advance >> pure (Index Identity (Literal (VStr k)) False, True)
          _ -> pure (Identity, False)
      TNum d -> advance >> pure (Literal (VNum d), False)
      TStr s -> advance >> pure (Literal (VStr s), False)
      TVar x -> advance >> pure (Var x, False)
      TSym "(" -> do
        advance
        e <- pipe
        expectSym ")"
        pure (e, False)
      TSym "[" -> do
        advance
        close <- sym "]"
        if close then pure (ArrayCons Nothing, False) else do
          e <- pipe
          expectSym "]"
          pure (ArrayCons (Just e), False)
      TSym "{" -> do
        advance
        close <- sym "}"
        if close then pure (ObjectCons [], False) else do
          es <- entries
          pure (ObjectCons es, False)
      TIdent "true" -> advance >> pure (Literal (VBool True), False)
      TIdent "false" -> advance >> pure (Literal (VBool False), False)
      TIdent "null" -> advance >> pure (Literal VNull, False)
      TIdent "if" -> advance >> ifExpr >>= \e -> pure (e, False)
      TIdent "reduce" -> do
        advance
        src <- postfix
        expectKw "as"
        mv <- peek
        case mv of
          Just (TVar x) -> do
            advance
            expectSym "("
            i <- pipe
            expectSym ";"
            u <- pipe
            expectSym ")"
            pure (Reduce src x i u, False)
          _ -> failP "expected variable in reduce"
      TIdent name
        | isKeyword name -> failP ("unexpected keyword " ++ T.unpack name)
        | otherwise -> do
            advance
            open <- sym "("
            if not open then pure (Call name [], False) else do
              args <- argList
              pure (Call name args, False)
      _ -> failP "unexpected token"

argList :: P [Expr]
argList = do
  a <- pipe
  semi <- sym ";"
  if semi then (a :) <$> argList else expectSym ")" >> pure [a]

ifExpr :: P Expr
ifExpr = do
  c <- pipe
  expectKw "then"
  a <- pipe
  e <- kw "elif"
  if e then do
    rest <- ifExpr
    pure (If c a (Just rest))
  else do
    hasElse <- kw "else"
    b <- if hasElse then Just <$> pipe else pure Nothing
    expectKw "end"
    pure (If c a b)

entries :: P [(Expr, Expr)]
entries = do
  e <- entry
  c <- sym ","
  if c then (e :) <$> entries else expectSym "}" >> pure [e]

entry :: P (Expr, Expr)
entry = do
  t <- peek
  case t of
    Just (TIdent k) -> advance >> keyed (Literal (VStr k)) (Just k)
    Just (TStr k) -> advance >> keyed (Literal (VStr k)) (Just k)
    Just (TVar x) -> advance >> pure (Literal (VStr x), Var x)
    Just (TSym "(") -> do
      advance
      k <- pipe
      expectSym ")"
      expectSym ":"
      v <- objVal
      pure (k, v)
    _ -> failP "bad object entry"
  where
    keyed k short = do
      colon <- sym ":"
      if colon then (,) k <$> objVal else case short of
        Just n -> pure (k, Index Identity (Literal (VStr n)) False)
        Nothing -> failP "bad object entry"

objVal :: P Expr
objVal = do
  a <- objTerm
  bar <- sym "|"
  if bar then Pipe a <$> objVal else pure a

objTerm :: P Expr
objTerm = do
  m <- sym "-"
  if m then Neg <$> objTerm else postfix

