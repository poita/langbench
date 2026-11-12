-- | Parsing of KBL: expressions, statements, block structure and string
-- literal contents.  Every failure is an @E_PARSE@ carrying the number of the
-- offending logical line.
module Kiln.Parser
  ( parseFile
  , parseSource
  , parseExprTokens
  , reservedWords
  ) where

import Control.Applicative (Alternative (..))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (nub)
import qualified Data.Set as Set

import Kiln.Lexer
import Kiln.Syntax

-- | The reserved words of KBL.
reservedWords :: Set.Set BS.ByteString
reservedWords =
  Set.fromList
    [ "abort", "after", "cmd", "cost", "default", "depfile", "each", "elsewhen"
    , "false", "in", "include", "let", "otherwise", "out", "phony", "rule"
    , "set", "step", "true", "use", "when"
    ]

-- ---------------------------------------------------------------------------
-- A tiny token-list parser

newtype P a = P {runP :: [Token] -> Maybe (a, [Token])}

instance Functor P where
  fmap f (P p) = P $ \ts -> case p ts of
    Nothing -> Nothing
    Just (a, r) -> Just (f a, r)

instance Applicative P where
  pure a = P $ \ts -> Just (a, ts)
  P pf <*> P pa = P $ \ts -> case pf ts of
    Nothing -> Nothing
    Just (f, r) -> case pa r of
      Nothing -> Nothing
      Just (a, r') -> Just (f a, r')

instance Monad P where
  P p >>= f = P $ \ts -> case p ts of
    Nothing -> Nothing
    Just (a, r) -> runP (f a) r

instance Alternative P where
  empty = P (const Nothing)
  P a <|> P b = P $ \ts -> case a ts of
    Nothing -> b ts
    r -> r

peek :: P (Maybe Token)
peek = P $ \ts -> Just (case ts of [] -> Nothing; t : _ -> Just t, ts)

peek2 :: P (Maybe Token)
peek2 = P $ \ts -> Just (case ts of _ : t : _ -> Just t; _ -> Nothing, ts)

next :: P Token
next = P $ \ts -> case ts of
  [] -> Nothing
  t : r -> Just (t, r)

sym :: BS.ByteString -> P ()
sym s = do
  t <- next
  if t == TSym s then pure () else empty

isSym :: BS.ByteString -> P Bool
isSym s = (== Just (TSym s)) <$> peek

-- | A non-reserved identifier.
ident :: P BS.ByteString
ident = do
  t <- next
  case t of
    TIdent w | not (Set.member w reservedWords) -> pure w
    _ -> empty

-- | Any identifier, reserved or not (call names, command names, rule names in @use@).
anyIdent :: P BS.ByteString
anyIdent = do
  t <- next
  case t of
    TIdent w -> pure w
    _ -> empty

keyword :: BS.ByteString -> P ()
keyword k = do
  t <- next
  if t == TIdent k then pure () else empty

atEnd :: P ()
atEnd = P $ \ts -> if null ts then Just ((), ts) else Nothing

runFull :: P a -> [Token] -> Maybe a
runFull p ts = case runP p ts of
  Just (a, []) -> Just a
  _ -> Nothing

-- | Parse a complete expression from a token list.
parseExprTokens :: [Token] -> Maybe Expr
parseExprTokens = runFull pExpr

-- | @item { "," item } [ "," ]@ followed by the closing symbol (consumed).
commaList :: BS.ByteString -> P a -> P [a]
commaList close item = do
  done <- isSym close
  if done
    then sym close >> pure []
    else do
      x <- item
      go [x]
  where
    go acc = do
      c <- isSym ","
      if c
        then do
          sym ","
          done <- isSym close
          if done then sym close >> pure (reverse acc) else item >>= \x -> go (x : acc)
        else sym close >> pure (reverse acc)

-- ---------------------------------------------------------------------------
-- Expressions

pExpr :: P Expr
pExpr = pOr >>= loop
  where
    loop e = do
      p <- isSym "|>"
      if not p
        then pure e
        else do
          sym "|>"
          name <- anyIdent
          o <- isSym "("
          args <- if o then sym "(" >> commaList ")" pExpr else pure []
          loop (ECall name (e : args))

binLevel :: [(BS.ByteString, BinOp)] -> P Expr -> P Expr
binLevel ops sub = sub >>= loop
  where
    loop l = do
      t <- peek
      case t of
        Just (TSym s) | Just op <- lookup s ops -> do
          _ <- next
          r <- sub
          loop (EBinary op l r)
        _ -> pure l

pOr, pAnd, pCmp, pCat, pStr, pAdd, pMul, pUnary, pPostfix, pPrimary :: P Expr
pOr = binLevel [("||", Or)] pAnd
pAnd = binLevel [("&&", And)] pCmp
pCmp = binLevel [("==", Eq), ("!=", Ne), ("<", Lt), ("<=", Le), (">", Gt), (">=", Ge)] pCat
pCat = binLevel [("++", ConcatList)] pStr
pStr = binLevel [("~", ConcatStr)] pAdd
pAdd = binLevel [("+", Add), ("-", Sub)] pMul
pMul = binLevel [("*", Mul), ("/", Div), ("%", Mod)] pUnary

pUnary = do
  t <- peek
  case t of
    Just (TSym "!") -> next >> EUnary Not <$> pUnary
    Just (TSym "-") -> next >> EUnary Neg <$> pUnary
    _ -> pPostfix

pPostfix = pPrimary >>= loop
  where
    loop e = do
      b <- isSym "["
      if b
        then do
          sym "["
          i <- pExpr
          sym "]"
          loop (EIndex e i)
        else pure e

pPrimary = do
  t <- next
  case t of
    TInt n -> pure (EInt n)
    TSq s -> pure (EStr s)
    TDq raw -> maybe empty pure (parseDq raw)
    TIdent w -> do
      o <- isSym "("
      if o
        then sym "(" >> ECall w <$> commaList ")" pExpr
        else case w of
          "true" -> pure (EBool True)
          "false" -> pure (EBool False)
          _ | Set.member w reservedWords -> empty
            | otherwise -> pure (EVar w)
    TSym "(" -> do
      e <- pExpr
      sym ")"
      pure e
    TSym "[" -> EList <$> commaList "]" pExpr
    _ -> empty

-- ---------------------------------------------------------------------------
-- String literals

-- | Parse the raw contents of a double-quoted literal into an expression.
parseDq :: BS.ByteString -> Maybe Expr
parseDq raw = do
  parts <- go 0 BS.empty []
  pure $ case parts of
    [] -> EStr BS.empty
    [PLit s] -> EStr s
    _ -> EInterp parts
  where
    n = BS.length raw
    flush lit acc = if BS.null lit then acc else PLit lit : acc
    go :: Int -> BS.ByteString -> [StrPart] -> Maybe [StrPart]
    go i lit acc
      | i >= n = Just (reverse (flush lit acc))
      | otherwise = case BC.index raw i of
          '\\' -> do
            if i + 1 >= n then Nothing else Just ()
            c <- case BC.index raw (i + 1) of
              '\\' -> Just "\\"
              '"' -> Just "\""
              'n' -> Just "\n"
              't' -> Just "\t"
              'r' -> Just "\r"
              '0' -> Just "\0"
              _ -> Nothing
            go (i + 2) (lit <> c) acc
          '{'
            | i + 1 < n && BC.index raw (i + 1) == '{' -> go (i + 2) (lit <> "{") acc
            | otherwise -> do
                j <- scanInterpolation raw (i + 1)
                let body = BS.take (j - 1 - (i + 1)) (BS.drop (i + 1) raw)
                toks <- tokenizeLine body
                if null toks then Nothing else Just ()
                e <- runFull pExpr toks
                go j BS.empty (PHole e : flush lit acc)
          '}'
            | i + 1 < n && BC.index raw (i + 1) == '}' -> go (i + 2) (lit <> "}") acc
            | otherwise -> Nothing
          c -> go (i + 1) (lit <> BC.singleton c) acc

-- ---------------------------------------------------------------------------
-- Simple statements and block headers

pSimple :: P Stmt
pSimple = do
  t <- next
  case t of
    TIdent "let" -> SLet <$> ident <* sym "=" <*> pExpr <* atEnd
    TIdent "set" -> SSet <$> ident <* sym "=" <*> pExpr <* atEnd
    TIdent "include" -> SInclude <$> pExpr <* atEnd
    TIdent "abort" -> SAbort <$> pExpr <* atEnd
    TIdent "default" -> SDefault <$> pExpr <* atEnd
    TIdent "phony" -> SPhony <$> ident <* sym "=" <*> pExpr <* atEnd
    TIdent "use" -> do
      name <- anyIdent
      sym "("
      args <- pUseArgs
      atEnd
      pure (SUse name args)
    _ -> empty

pUseArgs :: P [Arg]
pUseArgs = loop False []
  where
    loop seenKw acc = do
      done <- isSym ")"
      if done
        then sym ")" >> pure (reverse acc)
        else do
          a <- pArg seenKw
          let seen' = seenKw || isKw a
          c <- isSym ","
          if c then sym "," >> loop seen' (a : acc) else sym ")" >> pure (reverse (a : acc))
    isKw (Kw _ _) = True
    isKw _ = False

-- | One argument; positional arguments are rejected once a keyword was seen.
pArg :: Bool -> P Arg
pArg seenKw = do
  t <- peek
  t2 <- peek2
  case (t, t2) of
    (Just (TIdent w), Just (TSym "=")) | not (Set.member w reservedWords) -> do
      _ <- next
      _ <- next
      Kw w <$> pExpr
    _ -> if seenKw then empty else Pos <$> pExpr

data Header
  = HStep
  | HWhen Expr
  | HEach (Maybe BS.ByteString) BS.ByteString Expr
  | HRule BS.ByteString [Param]

-- | Parse a block header whose trailing @{@ has been removed.
pHeader :: P Header
pHeader = do
  t <- next
  case t of
    TIdent "step" -> atEnd >> pure HStep
    TIdent "when" -> HWhen <$> pExpr <* atEnd
    TIdent "each" -> do
      a <- ident
      c <- isSym ","
      if c
        then do
          sym ","
          b <- ident
          keyword "in"
          if a == b then empty else HEach (Just a) b <$> pExpr <* atEnd
        else keyword "in" >> HEach Nothing a <$> pExpr <* atEnd
    TIdent "rule" -> do
      name <- ident
      sym "("
      ps <- pParams
      atEnd
      let names = [n | Param n _ <- ps]
      if length (nub names) /= length names then empty else pure ()
      if validOrder ps then pure (HRule name ps) else empty
    _ -> empty
  where
    validOrder ps = go False ps
      where
        go _ [] = True
        go seenDefault (Param _ d : rest) = case d of
          Just _ -> go True rest
          Nothing -> not seenDefault && go seenDefault rest

pParams :: P [Param]
pParams = commaList ")" $ do
  n <- ident
  e <- isSym "="
  if e then sym "=" >> Param n . Just <$> pExpr else pure (Param n Nothing)

pStepField :: P StepField
pStepField = do
  t <- next
  case t of
    TIdent "out" -> FOut <$> pExpr <* atEnd
    TIdent "in" -> FIn <$> pExpr <* atEnd
    TIdent "after" -> FAfter <$> pExpr <* atEnd
    TIdent "cost" -> FCost <$> pExpr <* atEnd
    TIdent "depfile" -> FDepfile <$> pExpr <* atEnd
    TIdent "cmd" -> do
      name <- anyIdent
      sym "("
      args <- commaList ")" pExpr
      atEnd
      pure (FCmd name args)
    _ -> empty

-- ---------------------------------------------------------------------------
-- Block structure

data Term = TermClose | TermElsewhen Expr | TermOtherwise

data Stop = StopEOF | StopTerm Int Term [LogicalLine]

type R = Either Int

-- | Parse a whole file's logical lines into statements.  @Left n@ is the line
-- number of the reported @E_PARSE@.
parseFile :: [LogicalLine] -> Either Int [Stmt]
parseFile ls = do
  (stmts, stop) <- parseStmts ls
  case stop of
    StopEOF -> Right stmts
    StopTerm n _ _ -> Left n

-- | Lex and parse source text.
parseSource :: BS.ByteString -> Either Int [Stmt]
parseSource src = lexSource src >>= parseFile

classifyTerminator :: [Token] -> Maybe Term
classifyTerminator toks = case toks of
  [TSym "}"] -> Just TermClose
  TSym "}" : TIdent "elsewhen" : rest | not (null rest), last rest == TSym "{" ->
    TermElsewhen <$> runFull pExpr (init rest)
  [TSym "}", TIdent "otherwise", TSym "{"] -> Just TermOtherwise
  _ -> Nothing

parseStmts :: [LogicalLine] -> R ([Stmt], Stop)
parseStmts = go []
  where
    go acc [] = Right (reverse acc, StopEOF)
    go acc (LogicalLine n toks : rest) = case toks of
      TSym "}" : _ -> case classifyTerminator toks of
        Nothing -> Left n
        Just term -> Right (reverse acc, StopTerm n term rest)
      _
        | last toks == TSym "{" -> do
            hdr <- maybe (Left n) Right (runFull pHeader (init toks))
            (stmt, rest') <- parseBlock n hdr rest
            go (stmt : acc) rest'
        | otherwise -> do
            stmt <- maybe (Left n) Right (runFull pSimple toks)
            go (stmt : acc) rest

-- | Parse the body of a block opened at line @n@ by @hdr@.
parseBlock :: Int -> Header -> [LogicalLine] -> R (Stmt, [LogicalLine])
parseBlock n hdr rest = case hdr of
  HStep -> do
    (fields, rest') <- parseStepBody n rest
    pure (SStep fields, rest')
  HEach mi v e -> do
    (body, rest') <- closedBody n rest
    pure (SEach mi v e body, rest')
  HRule name ps -> do
    (body, rest') <- closedBody n rest
    pure (SRule name ps body, rest')
  HWhen c -> whenChain n [] c rest

-- | A body that must end in a plain @}@.
closedBody :: Int -> [LogicalLine] -> R ([Stmt], [LogicalLine])
closedBody n ls = do
  (body, stop) <- parseStmts ls
  case stop of
    StopEOF -> Left n
    StopTerm _ TermClose rest -> Right (body, rest)
    StopTerm m _ _ -> Left m

whenChain :: Int -> [(Expr, [Stmt])] -> Expr -> [LogicalLine] -> R (Stmt, [LogicalLine])
whenChain n branches cond ls = do
  (body, stop) <- parseStmts ls
  let branches' = branches ++ [(cond, body)]
  case stop of
    StopEOF -> Left n
    StopTerm _ TermClose rest -> Right (SWhen branches' Nothing, rest)
    StopTerm m (TermElsewhen c) rest -> whenChain m branches' c rest
    StopTerm m TermOtherwise rest -> do
      (ob, stop') <- parseStmts rest
      case stop' of
        StopEOF -> Left m
        StopTerm _ TermClose rest' -> Right (SWhen branches' (Just ob), rest')
        StopTerm m' _ _ -> Left m'

parseStepBody :: Int -> [LogicalLine] -> R ([StepField], [LogicalLine])
parseStepBody n = go []
  where
    go _ [] = Left n
    go acc (LogicalLine m toks : rest)
      | toks == [TSym "}"] = Right (reverse acc, rest)
      | otherwise = case runFull pStepField toks of
          Just f -> go (f : acc) rest
          Nothing -> Left m
