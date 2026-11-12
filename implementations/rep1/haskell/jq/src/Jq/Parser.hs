-- | Recursive-descent parser for filters.
module Jq.Parser
  ( parseFilter
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Jq.Lexer
import Jq.Syntax
import Jq.Value (Value (..))

newtype P a = P {runP :: [Token] -> Either String (a, [Token])}

instance Functor P where
  fmap f (P g) = P $ \ts -> case g ts of
    Left e -> Left e
    Right (a, r) -> Right (f a, r)

instance Applicative P where
  pure a = P $ \ts -> Right (a, ts)
  pf <*> pa = pf >>= \f -> fmap f pa

instance Monad P where
  P g >>= f = P $ \ts -> case g ts of
    Left e -> Left e
    Right (a, r) -> runP (f a) r

failP :: String -> P a
failP msg = P $ \ts -> Left (msg ++ " near " ++ show (take 3 ts))

peekT :: P (Maybe Token)
peekT = P $ \ts -> Right (case ts of [] -> Nothing; (t : _) -> Just t, ts)

-- | Token after the next one.
peek2 :: P (Maybe Token)
peek2 = P $ \ts -> Right (case ts of (_ : t : _) -> Just t; _ -> Nothing, ts)

advance :: P ()
advance = P $ \ts -> Right ((), drop 1 ts)

isSym :: String -> Maybe Token -> Bool
isSym s (Just (TSym s')) = s == s'
isSym _ _ = False

isKw :: String -> Maybe Token -> Bool
isKw s (Just (TIdent s')) = s == s'
isKw _ _ = False

expectSym :: String -> P ()
expectSym s = do
  t <- peekT
  if isSym s t then advance else failP ("expected " ++ show s)

expectKw :: String -> P ()
expectKw s = do
  t <- peekT
  if isKw s t then advance else failP ("expected " ++ show s)

-- | Consume the symbol if it is next.
optSym :: String -> P Bool
optSym s = do
  t <- peekT
  if isSym s t then advance >> pure True else pure False

-- | Parse a filter program.
parseFilter :: Text -> Either String Expr
parseFilter src = do
  toks <- tokenize (T.unpack src)
  (e, rest) <- runP pPipe toks
  case rest of
    [] -> Right e
    _ -> Left ("unexpected trailing tokens: " ++ show (take 3 rest))

pPipe :: P Expr
pPipe = do
  l <- pComma
  more <- optSym "|"
  if more then Pipe l <$> pPipe else pure l

pComma :: P Expr
pComma = do
  first <- pOr
  rest <- go
  pure (foldr1 Comma (first : rest))
  where
    go = do
      more <- optSym ","
      if more then (:) <$> pOr <*> go else pure []

pOr :: P Expr
pOr = pLeft "or" pAnd Or

pAnd :: P Expr
pAnd = pLeft "and" pCmp And

pLeft :: String -> P Expr -> (Expr -> Expr -> Expr) -> P Expr
pLeft kw operand mk = operand >>= go
  where
    go l = do
      t <- peekT
      if isKw kw t then advance >> operand >>= go . mk l else pure l

pCmp :: P Expr
pCmp = do
  l <- pAdd
  t <- peekT
  case t of
    Just (TSym s) | Just op <- lookup s ops -> advance >> Binary op l <$> pAdd
    _ -> pure l
  where
    ops = [("==", Eq), ("!=", Ne), ("<", Lt), ("<=", Le), (">", Gt), (">=", Ge)]

pAdd :: P Expr
pAdd = pBinary [("+", Add), ("-", Sub)] pMul

pMul :: P Expr
pMul = pBinary [("*", Mul), ("/", Div), ("%", Mod)] pUnary

pBinary :: [(String, BinOp)] -> P Expr -> P Expr
pBinary ops operand = operand >>= go
  where
    go l = do
      t <- peekT
      case t of
        Just (TSym s) | Just op <- lookup s ops -> advance >> operand >>= go . Binary op l
        _ -> pure l

pUnary :: P Expr
pUnary = do
  t <- peekT
  if isSym "-" t
    then advance >> Negate <$> pUnary
    else do
      e <- pPostfix
      t' <- peekT
      if isKw "as" t'
        then do
          advance
          name <- pVarName
          expectSym "|"
          Bind e name <$> pPipe
        else pure e

pVarName :: P String
pVarName = do
  t <- peekT
  case t of
    Just (TVar n) -> advance >> pure n
    _ -> failP "expected variable"

-- | A primary term followed by suffixes (without a trailing @as@ binding).
pPostfix :: P Expr
pPostfix = pPrimary >>= suffixes

suffixes :: Expr -> P Expr
suffixes t = do
  tok <- peekT
  case tok of
    Just (TField name) -> do
      advance
      e <- tolerant (Index t (Literal (VString name)) False)
      suffixes e
    Just (TSym "[") -> do
      advance
      e <- bracket t
      suffixes e
    Just (TSym "?") -> advance >> suffixes (Try t)
    _ -> pure t

-- | Apply an immediately following @?@ to the operation just parsed.
tolerant :: Expr -> P Expr
tolerant e = do
  q <- optSym "?"
  pure (if q then mark e else e)
  where
    mark (Index a k _) = Index a k True
    mark (Iterate a _) = Iterate a True
    mark (Slice a l h _) = Slice a l h True
    mark x = x

-- | Parse the inside of @[...]@ after the opening bracket.
bracket :: Expr -> P Expr
bracket t = do
  tok <- peekT
  if isSym "]" tok
    then advance >> tolerant (Iterate t False)
    else
      if isSym ":" tok
        then advance >> sliceHi Nothing
        else do
          e <- pPipe
          c <- optSym ":"
          if c
            then sliceHi (Just e)
            else expectSym "]" >> tolerant (Index t e False)
  where
    sliceHi lo = do
      tok <- peekT
      if isSym "]" tok
        then advance >> tolerant (Slice t lo Nothing False)
        else do
          hi <- pPipe
          expectSym "]"
          tolerant (Slice t lo (Just hi) False)

pPrimary :: P Expr
pPrimary = do
  tok <- peekT
  case tok of
    Nothing -> failP "unexpected end of filter"
    Just (TNum n) -> advance >> pure (Literal (VNumber n))
    Just (TStr s) -> advance >> pure (Literal (VString s))
    Just (TVar n) -> advance >> pure (Variable n)
    Just (TField name) -> do
      advance
      tolerant (Index Identity (Literal (VString name)) False)
    Just (TSym ".") -> advance >> pure Identity
    Just (TSym "(") -> do
      advance
      e <- pPipe
      expectSym ")"
      pure e
    Just (TSym "[") -> do
      advance
      c <- optSym "]"
      if c
        then pure (ArrayOf Nothing)
        else do
          e <- pPipe
          expectSym "]"
          pure (ArrayOf (Just e))
    Just (TSym "{") -> advance >> pObject
    Just (TIdent "true") -> advance >> pure (Literal (VBool True))
    Just (TIdent "false") -> advance >> pure (Literal (VBool False))
    Just (TIdent "null") -> advance >> pure (Literal VNull)
    Just (TIdent "if") -> advance >> pIf
    Just (TIdent "reduce") -> do
      advance
      src <- pPostfix
      expectKw "as"
      name <- pVarName
      expectSym "("
      ini <- pPipe
      expectSym ";"
      upd <- pPipe
      expectSym ")"
      pure (Reduce src name ini upd)
    Just (TIdent name) -> advance >> pCall name
    Just t -> failP ("unexpected token " ++ show t)

pIf :: P Expr
pIf = do
  c <- pPipe
  expectKw "then"
  a <- pPipe
  t <- peekT
  case t of
    Just (TIdent "elif") -> advance >> If c a <$> pIf
    Just (TIdent "else") -> do
      advance
      b <- pPipe
      expectKw "end"
      pure (If c a b)
    _ -> expectKw "end" >> pure (If c a Identity)

pCall :: String -> P Expr
pCall name = do
  t <- peekT
  args <-
    if isSym "(" t
      then do
        advance
        a <- pPipe
        more <- semis
        expectSym ")"
        pure (a : more)
      else pure []
  case (name, args) of
    ("empty", []) -> pure (Call0 Empty)
    ("error", []) -> pure (Call0 Error)
    ("not", []) -> pure (Call0 Not)
    ("length", []) -> pure (Call0 Length)
    ("keys", []) -> pure (Call0 Keys)
    ("type", []) -> pure (Call0 Type)
    ("add", []) -> pure (Call0 AddAll)
    ("reverse", []) -> pure (Call0 Reverse)
    ("sort", []) -> pure (Call0 Sort)
    ("unique", []) -> pure (Call0 Unique)
    ("min", []) -> pure (Call0 Min)
    ("max", []) -> pure (Call0 Max)
    ("tostring", []) -> pure (Call0 ToString)
    ("tonumber", []) -> pure (Call0 ToNumber)
    ("select", [f]) -> pure (Call1 Select f)
    ("map", [f]) -> pure (Call1 Map f)
    ("sort_by", [f]) -> pure (Call1 SortBy f)
    ("group_by", [f]) -> pure (Call1 GroupBy f)
    ("has", [f]) -> pure (Call1 Has f)
    ("error", [f]) -> pure (Call1 ErrorWith f)
    _ -> failP ("unknown builtin " ++ name ++ "/" ++ show (length args))
  where
    semis = do
      more <- optSym ";"
      if more then (:) <$> pPipe <*> semis else pure []

pObject :: P Expr
pObject = do
  c <- optSym "}"
  if c
    then pure (ObjectOf [])
    else do
      es <- entries
      pure (ObjectOf es)
  where
    entries = do
      e <- pEntry
      more <- optSym ","
      if more then (e :) <$> entries else expectSym "}" >> pure [e]

pEntry :: P (Expr, Expr)
pEntry = do
  tok <- peekT
  nxt <- peek2
  case tok of
    Just (TIdent k) | isSym ":" nxt -> advance >> advance >> (,) (key k) <$> pObjVal
                    | otherwise -> advance >> pure (key k, Index Identity (key k) False)
    Just (TStr k) | isSym ":" nxt -> advance >> advance >> (,) (key' k) <$> pObjVal
                  | otherwise -> advance >> pure (key' k, Index Identity (key' k) False)
    Just (TVar n) -> advance >> pure (key n, Variable n)
    Just (TSym "(") -> do
      advance
      k <- pPipe
      expectSym ")"
      expectSym ":"
      (,) k <$> pObjVal
    _ -> failP "bad object entry"
  where
    key = Literal . VString . T.pack
    key' = Literal . VString

pObjVal :: P Expr
pObjVal = do
  t <- pObjTerm
  more <- optSym "|"
  if more then Pipe t <$> pObjVal else pure t

pObjTerm :: P Expr
pObjTerm = do
  t <- peekT
  if isSym "-" t then advance >> Negate <$> pObjTerm else pPostfix
