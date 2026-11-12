-- | A recursive-descent parser with precedence climbing (SPEC.md section 4).
module Langvm.Parser
  ( parseModule
  ) where

import Langvm.Diagnostic
import Langvm.Lexer
import Langvm.Syntax

-- Parser monad -----------------------------------------------------------------

newtype P a = P { unP :: [Token] -> Either Pos (a, [Token]) }

instance Functor P where
  fmap f (P g) = P $ \ts -> case g ts of
    Left e -> Left e
    Right (a, r) -> Right (f a, r)

instance Applicative P where
  pure a = P $ \ts -> Right (a, ts)
  P f <*> P g = P $ \ts -> case f ts of
    Left e -> Left e
    Right (h, r) -> case g r of
      Left e -> Left e
      Right (a, r') -> Right (h a, r')

instance Monad P where
  P g >>= f = P $ \ts -> case g ts of
    Left e -> Left e
    Right (a, r) -> unP (f a) r

peek :: P Token
peek = P $ \ts -> case ts of
  (t : _) -> Right (t, ts)
  [] -> Left (Pos 1 1)  -- unreachable: the stream ends with a sentinel

peekAt :: Int -> P Tok
peekAt n = P $ \ts -> Right (case drop n ts of (t : _) -> tokTok t; [] -> TSym "<eof>", ts)

advance :: P Token
advance = P $ \ts -> case ts of
  (t : r) -> Right (t, if null r then [t] else r)
  [] -> Left (Pos 1 1)

failHere :: P a
failHere = do
  t <- peek
  P $ \_ -> Left (tokPos t)

-- | Replace the current @>>@ token by a single @>@ (closing one of two lists).
splitShift :: P ()
splitShift = P $ \ts -> case ts of
  (Token _ (Pos l c) : r) -> Right ((), Token (TSym ">") (Pos l (c + 1)) : r)
  [] -> Right ((), [])

isSym :: String -> P Bool
isSym s = (\t -> tokTok t == TSym s) <$> peek

isKw :: String -> P Bool
isKw s = (\t -> tokTok t == TKw s) <$> peek

acceptSym :: String -> P Bool
acceptSym s = do
  b <- isSym s
  if b then advance >> return True else return False

acceptKw :: String -> P Bool
acceptKw s = do
  b <- isKw s
  if b then advance >> return True else return False

expectSym :: String -> P Token
expectSym s = do
  b <- isSym s
  if b then advance else failHere

expectKw :: String -> P Token
expectKw s = do
  b <- isKw s
  if b then advance else failHere

identTok :: P Ident
identTok = do
  t <- peek
  case tokTok t of
    TIdent n -> advance >> return (Ident n (tokPos t))
    _ -> failHere

-- | Parse a comma-separated list with an optional trailing comma, up to (but
-- not consuming) the closing symbol.  The list may be empty.
commaList :: String -> P a -> P [a]
commaList close item = do
  e <- isSym close
  if e then return [] else go
  where
    go = do
      x <- item
      c <- acceptSym ","
      if not c then return [x] else do
        e <- isSym close
        if e then return [x] else (x :) <$> go

-- | Like 'commaList' but with at least one element.
commaList1 :: String -> P a -> P [a]
commaList1 close item = do
  x <- item
  c <- acceptSym ","
  if not c then return [x] else do
    e <- isSym close
    if e then return [x] else (x :) <$> commaList1 close item

-- Entry point ------------------------------------------------------------------

-- | Parse a module's token list.  The position is where an input that ends
-- too early is reported.
parseModule :: String -> Pos -> [Token] -> Either Diagnostic Module
parseModule name eofPos toks =
  case unP body (toks ++ [Token (TSym "<eof>") eofPos]) of
    Left p -> Left (Diagnostic ParseError p)
    Right (m, _) -> Right m
  where
    body = do
      items <- many'
      return (Module name items)
    many' = do
      t <- peek
      case tokTok t of
        TSym "<eof>" -> return []
        _ -> (:) <$> item <*> many'

-- Items ------------------------------------------------------------------------

item :: P Item
item = do
  t <- peek
  case tokTok t of
    TKw "use" -> do
      _ <- advance
      m <- identTok
      a <- acceptKw "as"
      alias <- if a then Just <$> identTok else return Nothing
      _ <- expectSym ";"
      return (IUse (tokPos t) m alias)
    TKw "impl" -> IImpl <$> implDecl
    TKw "pub" -> advance >> declItem True
    _ -> declItem False

declItem :: Bool -> P Item
declItem pub = do
  t <- peek
  case tokTok t of
    TKw "fn" -> IFn <$> fnDecl pub
    TKw "struct" -> do
      _ <- advance
      n <- identTok
      g <- generics False
      _ <- expectSym "{"
      fs <- commaList "}" param
      _ <- expectSym "}"
      return (IStruct (StructDecl pub (tokPos t) n g fs))
    TKw "enum" -> do
      _ <- advance
      n <- identTok
      g <- generics False
      _ <- expectSym "{"
      vs <- commaList "}" variant
      _ <- expectSym "}"
      return (IEnum (EnumDecl pub (tokPos t) n g vs))
    TKw "trait" -> do
      _ <- advance
      n <- identTok
      _ <- expectSym "{"
      ms <- methods True
      _ <- expectSym "}"
      return (ITrait (TraitDecl pub (tokPos t) n ms))
    _ -> failHere

param :: P Param
param = do
  n <- identTok
  _ <- expectSym ":"
  Param n <$> typeExpr

variant :: P Variant
variant = do
  n <- identTok
  o <- acceptSym "("
  ps <- if o then commaList1 ")" typeExpr <* expectSym ")" else return []
  return (Variant n ps)

fnDecl :: Bool -> P FnDecl
fnDecl pub = do
  kw <- expectKw "fn"
  n <- identTok
  g <- generics True
  _ <- expectSym "("
  ps <- commaList ")" param
  _ <- expectSym ")"
  r <- retType
  b <- block
  return (FnDecl pub (tokPos kw) n g ps r b)

retType :: P (Maybe TypeExpr)
retType = do
  a <- acceptSym "->"
  if a then Just <$> typeExpr else return Nothing

generics :: Bool -> P [GenParam]
generics allowBounds = do
  o <- acceptSym "<"
  if not o then return [] else do
    gs <- commaList1 ">" (genParam allowBounds)
    _ <- expectSym ">"
    return gs

genParam :: Bool -> P GenParam
genParam allowBounds = do
  n <- identTok
  c <- isSym ":"
  if c && not allowBounds then failHere else do
    _ <- acceptSym ":"
    bs <- if c then bounds else return []
    return (GenParam n bs)
  where
    bounds = do
      b <- traitRef
      p <- acceptSym "+"
      if p then (b :) <$> bounds else return [b]

traitRef :: P TraitRef
traitRef = do
  a <- identTok
  q <- acceptSym "::"
  if q then TraitRef (Just a) <$> identTok else return (TraitRef Nothing a)

implDecl :: P ImplDecl
implDecl = do
  kw <- expectKw "impl"
  g <- generics True
  tr <- traitRef
  _ <- expectKw "for"
  h <- typeExpr
  _ <- expectSym "{"
  ms <- methods False
  _ <- expectSym "}"
  return (ImplDecl (tokPos kw) g tr h ms)

-- | Methods until the closing brace; @allowNoBody@ permits @;@ (traits).
methods :: Bool -> P [Method]
methods allowNoBody = do
  e <- isSym "}"
  if e then return [] else (:) <$> method <*> methods allowNoBody
  where
    method = do
      kw <- expectKw "fn"
      n <- identTok
      _ <- expectSym "("
      _ <- expectKw "self"
      c <- acceptSym ","
      ps <- if c then commaList1 ")" param else return []
      _ <- expectSym ")"
      r <- retType
      semi <- if allowNoBody then isSym ";" else return False
      if semi
        then advance >> return (Method (tokPos kw) n ps r Nothing)
        else Method (tokPos kw) n ps r . Just <$> block

-- Types ------------------------------------------------------------------------

typeExpr :: P TypeExpr
typeExpr = do
  t <- peek
  let pos = tokPos t
      mk = return . TypeExpr pos
  case tokTok t of
    TSym "[" -> do
      _ <- advance
      e <- typeExpr
      _ <- expectSym "]"
      mk (TyList e)
    TSym "#[" -> do
      _ <- advance
      k <- typeExpr
      _ <- expectSym ":"
      v <- typeExpr
      _ <- expectSym "]"
      mk (TyMap k v)
    TSym "(" -> do
      _ <- advance
      a <- typeExpr
      _ <- expectSym ","
      rest <- commaList1 ")" typeExpr
      _ <- expectSym ")"
      mk (TyTuple (a : rest))
    TKw "fn" -> do
      _ <- advance
      _ <- expectSym "("
      ps <- commaList ")" typeExpr
      _ <- expectSym ")"
      r <- retType
      mk (TyFn ps r)
    TIdent _ -> do
      a <- identTok
      q <- acceptSym "::"
      (qual, nm) <- if q then (\b -> (Just a, b)) <$> identTok else return (Nothing, a)
      lt <- acceptSym "<"
      args <- if lt then typeArgs else return []
      mk (TyPath qual nm args)
    _ -> failHere

-- | After the opening @<@: arguments and the closing @>@ (or half of @>>@).
typeArgs :: P [TypeExpr]
typeArgs = do
  as <- commaList1 ">" typeExpr
  t <- peek
  case tokTok t of
    TSym ">" -> advance >> return as
    TSym ">>" -> splitShift >> return as
    _ -> failHere

-- Blocks and statements ----------------------------------------------------------

block :: P Block
block = do
  o <- expectSym "{"
  (ss, tl) <- stmts
  return (Block (tokPos o) ss tl)

-- | Statements up to and including the closing brace.
stmts :: P ([Stmt], Maybe Expr)
stmts = do
  t <- peek
  let pos = tokPos t
  case tokTok t of
    TSym "}" -> advance >> return ([], Nothing)
    TKw "let" -> do
      _ <- advance
      p <- pattern
      c <- acceptSym ":"
      ty <- if c then Just <$> typeExpr else return Nothing
      _ <- expectSym "="
      e <- expr
      _ <- expectSym ";"
      next (SLet pos p ty e)
    TKw "var" -> do
      _ <- advance
      n <- identTok
      c <- acceptSym ":"
      ty <- if c then Just <$> typeExpr else return Nothing
      _ <- expectSym "="
      e <- expr
      _ <- expectSym ";"
      next (SVar pos n ty e)
    TKw "return" -> do
      _ <- advance
      s <- isSym ";"
      e <- if s then return Nothing else Just <$> expr
      _ <- expectSym ";"
      next (SReturn pos e)
    TKw "while" -> do
      _ <- advance
      c <- expr
      b <- block
      next (SWhile pos c b)
    TKw "for" -> do
      _ <- advance
      p <- pattern
      _ <- expectKw "in"
      e <- expr
      r <- acceptSym ".."
      hi <- if r then Just <$> expr else return Nothing
      b <- block
      next (SFor pos p e hi b)
    TKw "break" -> advance >> expectSym ";" >> next (SBreak pos)
    TKw "continue" -> advance >> expectSym ";" >> next (SContinue pos)
    _ -> do
      e <- expr
      t' <- peek
      case tokTok t' of
        TSym "=" -> do
          _ <- advance
          v <- expr
          _ <- expectSym ";"
          next (SAssign e v)
        TSym ";" -> advance >> next (SExpr e)
        TSym "}" -> advance >> return ([], Just e)
        _ | endsWithoutSemicolon e -> next (SExpr e)
          | otherwise -> failHere
  where
    next s = do
      (ss, tl) <- stmts
      return (s : ss, tl)
    endsWithoutSemicolon e = case exprNode e of
      EIf {} -> True
      EMatch {} -> True
      _ -> False

-- Expressions ------------------------------------------------------------------

expr :: P Expr
expr = leftAssoc [("||", OpOr)] andExpr

andExpr :: P Expr
andExpr = leftAssoc [("&&", OpAnd)] cmpExpr

cmpExpr :: P Expr
cmpExpr = do
  l <- bitOr
  t <- peek
  case lookup' (tokTok t) of
    Nothing -> return l
    Just op -> do
      _ <- advance
      r <- bitOr
      t' <- peek
      case lookup' (tokTok t') of
        Just _ -> failHere
        Nothing -> return (Expr (exprPos l) (EBinary op l r))
  where
    lookup' (TSym s) = lookup s
      [("==", OpEq), ("!=", OpNe), ("<", OpLt), ("<=", OpLe), (">", OpGt), (">=", OpGe)]
    lookup' _ = Nothing

bitOr, bitXor, bitAnd, shiftE, addE, mulE :: P Expr
bitOr = leftAssoc [("|", OpBitOr)] bitXor
bitXor = leftAssoc [("^", OpBitXor)] bitAnd
bitAnd = leftAssoc [("&", OpBitAnd)] shiftE
shiftE = leftAssoc [("<<", OpShl), (">>", OpShr)] addE
addE = leftAssoc [("+", OpAdd), ("-", OpSub), ("++", OpConcat)] mulE
mulE = leftAssoc [("*", OpMul), ("/", OpDiv), ("%", OpMod)] unary

leftAssoc :: [(String, BinOp)] -> P Expr -> P Expr
leftAssoc ops sub = sub >>= loop
  where
    loop l = do
      t <- peek
      case tokTok t of
        TSym s | Just op <- lookup s ops -> do
          _ <- advance
          r <- sub
          loop (Expr (exprPos l) (EBinary op l r))
        _ -> return l

unary :: P Expr
unary = do
  t <- peek
  let un op = do
        _ <- advance
        e <- unary
        return (Expr (tokPos t) (EUnary op e))
  case tokTok t of
    TSym "-" -> un UNeg
    TSym "!" -> un UNot
    TSym "~" -> un UBitNot
    _ -> postfix

postfix :: P Expr
postfix = primary >>= loop
  where
    loop e = do
      t <- peek
      case tokTok t of
        TSym "(" -> do
          _ <- advance
          as <- commaList ")" expr
          _ <- expectSym ")"
          loop (Expr (exprPos e) (ECall e as))
        TSym "[" -> do
          _ <- advance
          i <- expr
          _ <- expectSym "]"
          loop (Expr (exprPos e) (EIndex e i))
        TSym "." -> do
          _ <- advance
          n <- identTok
          o <- acceptSym "("
          if o
            then do
              as <- commaList ")" expr
              _ <- expectSym ")"
              loop (Expr (exprPos e) (EMethod e n as))
            else loop (Expr (exprPos e) (EField e n))
        _ -> return e

primary :: P Expr
primary = do
  t <- peek
  let pos = tokPos t
      lit n = advance >> return (Expr pos n)
  case tokTok t of
    TInt n -> lit (EInt n)
    TFloat d -> lit (EFloat d)
    TStr s -> lit (EStr s)
    TChar c -> lit (EChar c)
    TKw "true" -> lit (EBool True)
    TKw "false" -> lit (EBool False)
    TKw "self" -> lit ESelf
    TSym "(" -> do
      _ <- advance
      e <- expr
      c <- acceptSym ","
      if c
        then do
          rest <- commaList1 ")" expr
          _ <- expectSym ")"
          return (Expr pos (ETuple (e : rest)))
        else expectSym ")" >> return e
    TSym "[" -> do
      _ <- advance
      es <- commaList "]" expr
      _ <- expectSym "]"
      return (Expr pos (EList es))
    TSym "#[" -> do
      _ <- advance
      es <- commaList "]" mapEntry
      _ <- expectSym "]"
      return (Expr pos (EMap es))
    TSym "||" -> lambda
    TSym "|" -> lambda
    TKw "if" -> ifExpr
    TKw "match" -> matchExpr
    TIdent _ -> do
      p <- valuePath
      d <- peekAt 0
      b <- peekAt 1
      if d == TSym "." && b == TSym "{"
        then do
          _ <- advance
          _ <- advance
          fs <- commaList "}" fieldInit
          _ <- expectSym "}"
          return (Expr pos (EStructLit p fs))
        else return (Expr pos (EPath p))
    _ -> failHere
  where
    mapEntry = do
      k <- expr
      _ <- expectSym ":"
      v <- expr
      return (k, v)
    fieldInit = do
      n <- identTok
      _ <- expectSym ":"
      e <- expr
      return (n, e)

valuePath :: P Path
valuePath = do
  a <- identTok
  q <- acceptSym "::"
  if q then Path (Just a) <$> identTok else return (Path Nothing a)

lambda :: P Expr
lambda = do
  t <- peek
  _ <- advance
  ps <- case tokTok t of
    TSym "||" -> return []
    _ -> do
      xs <- commaList1 "|" lparam
      _ <- expectSym "|"
      return xs
  r <- retType
  o <- isSym "{"
  body <- if o
    then do
      b <- block
      return (Expr (blockPos b) (EBlock b))
    else expr
  return (Expr (tokPos t) (ELambda (Lambda (tokPos t) ps r body)))
  where
    lparam = do
      n <- identTok
      c <- acceptSym ":"
      ty <- if c then Just <$> typeExpr else return Nothing
      return (n, ty)

ifExpr :: P Expr
ifExpr = do
  kw <- expectKw "if"
  c <- expr
  b <- block
  e <- acceptKw "else"
  els <- if not e then return Nothing else do
    i <- isKw "if"
    if i then Just <$> ifExpr else do
      eb <- block
      return (Just (Expr (blockPos eb) (EBlock eb)))
  return (Expr (tokPos kw) (EIf c b els))

matchExpr :: P Expr
matchExpr = do
  kw <- expectKw "match"
  s <- expr
  _ <- expectSym "{"
  arms <- armList
  return (Expr (tokPos kw) (EMatch s arms))
  where
    armList = do
      e <- isSym "}"
      if e then advance >> return [] else do
        p <- pattern
        g <- acceptKw "when"
        guard' <- if g then Just <$> expr else return Nothing
        _ <- expectSym "->"
        o <- isSym "{"
        (body, isBlock) <- if o
          then do
            b <- block
            return (Expr (blockPos b) (EBlock b), True)
          else (\x -> (x, False)) <$> expr
        let arm = Arm p guard' body
        c <- acceptSym ","
        if c then (arm :) <$> armList else do
          e' <- isSym "}"
          if e' then advance >> return [arm]
          else if isBlock then (arm :) <$> armList
          else failHere

-- Patterns ---------------------------------------------------------------------

pattern :: P Pattern
pattern = do
  t <- peek
  let pos = tokPos t
      mk = return . Pattern pos
  case tokTok t of
    TSym "_" -> advance >> mk PWild
    TInt n -> advance >> mk (PInt n)
    TFloat _ -> advance >> mk PFloat
    TStr s -> advance >> mk (PStr s)
    TChar c -> advance >> mk (PChar c)
    TKw "true" -> advance >> mk (PBool True)
    TKw "false" -> advance >> mk (PBool False)
    TSym "-" -> do
      _ <- advance
      n <- peek
      case tokTok n of
        TInt v -> advance >> mk (PInt (negate v))
        TFloat _ -> advance >> mk PFloat
        _ -> failHere
    TSym "(" -> do
      _ <- advance
      a <- pattern
      _ <- expectSym ","
      rest <- commaList1 ")" pattern
      _ <- expectSym ")"
      mk (PTuple (a : rest))
    TSym "[" -> do
      _ <- advance
      listPat pos
    TIdent _ -> do
      p <- valuePath
      d <- peekAt 0
      b <- peekAt 1
      o <- peekAt 0
      if d == TSym "." && b == TSym "{"
        then do
          _ <- advance
          _ <- advance
          (fs, rest) <- fieldPats
          mk (PStruct p fs rest)
        else if o == TSym "("
          then do
            _ <- advance
            ps <- commaList1 ")" pattern
            _ <- expectSym ")"
            mk (PVariant p ps)
          else mk (PIdent p)
    _ -> failHere
  where
    listPat pos = go []
      where
        go acc = do
          t <- peek
          case tokTok t of
            TSym "]" -> advance >> done acc Nothing
            TSym ".." -> do
              _ <- advance
              n <- peek
              rest <- case tokTok n of
                TIdent nm -> advance >> return (Just (Ident nm (tokPos n)))
                _ -> return Nothing
              _ <- expectSym "]"
              done acc (Just rest)
            _ -> do
              p <- pattern
              c <- acceptSym ","
              if c then go (p : acc) else do
                _ <- expectSym "]"
                done (p : acc) Nothing
        done acc rest = return (Pattern pos (PList (reverse acc) rest))
    fieldPats = go []
      where
        go acc = do
          t <- peek
          case tokTok t of
            TSym "}" -> advance >> return (reverse acc, False)
            TSym ".." -> do
              _ <- advance
              _ <- expectSym "}"
              return (reverse acc, True)
            _ -> do
              n <- identTok
              c <- acceptSym ":"
              p <- if c then Just <$> pattern else return Nothing
              cm <- acceptSym ","
              if cm then go ((n, p) : acc) else do
                _ <- expectSym "}"
                return (reverse ((n, p) : acc), False)
