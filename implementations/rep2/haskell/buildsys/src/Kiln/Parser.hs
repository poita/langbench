-- | Parsing KBL source into a syntax tree.
module Kiln.Parser
  ( parseSource
  , parseBuildFile
  , reservedWords
  ) where

import Control.Monad (unless, when)
import Control.Monad.State.Strict
import qualified Data.ByteString as B
import Data.List (nub)
import qualified Data.Set as S

import Kiln.Error
import Kiln.Lexer
import Kiln.Syntax

-- | The words that cannot be used as variable, parameter, rule or loop names.
reservedWords :: S.Set B.ByteString
reservedWords =
  S.fromList
    [ "abort", "after", "cmd", "cost", "default", "depfile", "each", "elsewhen"
    , "false", "in", "include", "let", "otherwise", "out", "phony", "rule"
    , "set", "step", "true", "use", "when" ]

-- | Parse a build file, reporting failures as @E_PARSE <path>:<line>@.
parseBuildFile :: B.ByteString -> B.ByteString -> Either BuildError [Stmt]
parseBuildFile path src = either (Left . EParse path) Right (parseSource src)

-- | Parse KBL source. 'Left' is the line number of the error that must be
-- reported: the earliest lexical error, else the first grammar error, else an
-- unterminated block.
parseSource :: B.ByteString -> Either Int [Stmt]
parseSource src = do
  ls <- lexFile src
  (stmts, rest) <- parseStmts ls
  case rest of
    Nothing -> Right stmts
    Just (l, _) -> Left (llNumber l) -- block terminator with no open block

------------------------------------------------------------------------
-- Token-level parser

type P = StateT [Token] (Either ())

failP :: P a
failP = lift (Left ())

peek :: P (Maybe Token)
peek = gets (\case [] -> Nothing; t : _ -> Just t)

peek2 :: P (Maybe Token)
peek2 = gets (\case _ : t : _ -> Just t; _ -> Nothing)

advance :: P ()
advance = modify (drop 1)

sym :: B.ByteString -> P ()
sym s = peek >>= \case
  Just (TSym t) | t == s -> advance
  _ -> failP

isSym :: B.ByteString -> Maybe Token -> Bool
isSym s (Just (TSym t)) = s == t
isSym _ _ = False

-- | Any identifier, reserved or not.
identAny :: P B.ByteString
identAny = peek >>= \case
  Just (TIdent n) -> advance >> pure n
  _ -> failP

-- | A non-reserved identifier.
identName :: P B.ByteString
identName = do
  n <- identAny
  when (n `S.member` reservedWords) failP
  pure n

keyword :: B.ByteString -> P ()
keyword k = identAny >>= \n -> unless (n == k) failP

atEnd :: P ()
atEnd = get >>= \case [] -> pure (); _ -> failP

runP :: P a -> [Token] -> Either () a
runP p ts = evalStateT (p <* atEnd) ts

exprP :: P Expr
exprP = pipeE

pipeE :: P Expr
pipeE = orE >>= loop
  where
    loop e = peek >>= \case
      Just (TSym "|>") -> do
        advance
        name <- identAny
        args <- peek >>= \t -> if isSym "(" t then callArgs else pure []
        loop (ECall name (e : args))
      _ -> pure e

-- | @( [expr {, expr} [,]] )@
callArgs :: P [Expr]
callArgs = sym "(" *> commaList ")" exprP

-- | A comma separated list closed by the given symbol (which it consumes);
-- a trailing comma is allowed.
commaList :: B.ByteString -> P a -> P [a]
commaList close item = peek >>= \t ->
  if isSym close t
    then advance >> pure []
    else go
  where
    go = do
      x <- item
      peek >>= \case
        Just (TSym ",") -> do
          advance
          t <- peek
          if isSym close t then advance >> pure [x] else (x :) <$> go
        Just (TSym s) | s == close -> advance >> pure [x]
        _ -> failP

binLevel :: [(B.ByteString, BinOp)] -> P Expr -> P Expr
binLevel ops next = next >>= loop
  where
    loop l = peek >>= \case
      Just (TSym s) | Just op <- lookup s ops -> do
        advance
        r <- next
        loop (EBinary op l r)
      _ -> pure l

orE, andE, cmpE, catE, strE, addE, mulE, unaryE, postfixE, primaryE :: P Expr
orE = binLevel [("||", Or)] andE
andE = binLevel [("&&", And)] cmpE
cmpE = binLevel [("==", Eq), ("!=", Ne), ("<=", Le), ("<", Lt), (">=", Ge), (">", Gt)] catE
catE = binLevel [("++", ListCat)] strE
strE = binLevel [("~", StrCat)] addE
addE = binLevel [("+", Add), ("-", Sub)] mulE
mulE = binLevel [("*", Mul), ("/", Div), ("%", Mod)] unaryE

unaryE = peek >>= \case
  Just (TSym "!") -> advance >> EUnary Not <$> unaryE
  Just (TSym "-") -> advance >> EUnary Neg <$> unaryE
  _ -> postfixE

postfixE = primaryE >>= loop
  where
    loop e = peek >>= \case
      Just (TSym "[") -> do
        advance
        i <- exprP
        sym "]"
        loop (EIndex e i)
      Just (TSym "(") -> failP -- a call applies only to an identifier
      _ -> pure e

primaryE = peek >>= \case
  Just (TInt n) -> advance >> pure (EIntLit n)
  Just (TSQ s) -> advance >> pure (EStrLit s)
  Just (TDQ raw) -> advance >> literalE raw
  Just (TSym "(") -> advance *> exprP <* sym ")"
  Just (TSym "[") -> advance >> EListLit <$> commaList "]" exprP
  Just (TIdent n) -> do
    next <- peek2
    if isSym "(" next
      then advance >> ECall n <$> callArgs
      else do
        advance
        if
          | n == "true" -> pure (EBoolLit True)
          | n == "false" -> pure (EBoolLit False)
          | n `S.member` reservedWords -> failP
          | otherwise -> pure (EVar n)
  _ -> failP

literalE :: B.ByteString -> P Expr
literalE raw = case readDoubleQuoted raw of
  Nothing -> failP
  Just parts -> do
    parts' <- mapM toPart parts
    pure $ case parts' of
      [] -> EStrLit B.empty
      [PLit s] -> EStrLit s
      _ -> EInterpLit parts'
  where
    toPart (RLit s) = pure (PLit s)
    toPart (RInterp toks) = either (const failP) (pure . PExpr) (runP exprP toks)

------------------------------------------------------------------------
-- Line-level parser

-- | Parse statements until a block terminator or the end of the file.
-- Returns the terminator line (unconsumed) and the lines after it.
parseStmts :: [LogicalLine] -> Either Int ([Stmt], Maybe (LogicalLine, [LogicalLine]))
parseStmts = go []
  where
    go acc [] = Right (reverse acc, Nothing)
    go acc (l : ls) = case llTokens l of
      TSym "}" : _ -> Right (reverse acc, Just (l, ls))
      toks
        | Just (TSym "{") <- lastMay toks -> do
            (st, ls') <- parseBlock l (init toks) ls
            go (st : acc) ls'
        | otherwise -> do
            st <- liftLine l (simpleStmt toks)
            go (st : acc) ls

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)

liftLine :: LogicalLine -> P a -> Either Int a
liftLine l p = either (const (Left (llNumber l))) Right (runP p (llTokens l))

liftToks :: LogicalLine -> [Token] -> P a -> Either Int a
liftToks l toks p = either (const (Left (llNumber l))) Right (runP p toks)

simpleStmt :: [Token] -> P Stmt
simpleStmt _ = do
  kw <- identAny
  case kw of
    "let" -> SLet <$> identName <* sym "=" <*> exprP
    "set" -> SSet <$> identName <* sym "=" <*> exprP
    "include" -> SInclude <$> exprP
    "abort" -> SAbort <$> exprP
    "default" -> SDefault <$> exprP
    "phony" -> SPhony <$> identName <* sym "=" <*> exprP
    "use" -> do
      name <- identAny
      sym "("
      args <- commaList ")" argP
      checkOrder args
      pure (SUse name args)
    _ -> failP
  where
    checkOrder args = go False args
      where
        go _ [] = pure ()
        go seenKw (Positional _ : r) = if seenKw then failP else go seenKw r
        go _ (Keyword _ _ : r) = go True r

argP :: P Arg
argP = do
  t1 <- peek
  t2 <- peek2
  case (t1, t2) of
    (Just (TIdent k), Just (TSym "=")) | not (k `S.member` reservedWords) ->
      advance >> advance >> Keyword k <$> exprP
    _ -> Positional <$> exprP

-- | Parse a block whose header line has the given tokens (without the
-- trailing @{@), and whose body starts at the given lines.
parseBlock :: LogicalLine -> [Token] -> [LogicalLine] -> Either Int (Stmt, [LogicalLine])
parseBlock hdr toks ls = case toks of
  [TIdent "step"] -> do
    (fields, ls') <- parseStepBody hdr ls
    pure (SStep fields, ls')
  TIdent "when" : rest -> do
    cond <- liftToks hdr rest exprP
    whenChain hdr [] cond ls
  TIdent "each" : rest -> do
    (mi, n, subj) <- liftToks hdr rest eachHead
    (body, ls') <- closedBody hdr ls
    pure (SEach mi n subj body, ls')
  TIdent "rule" : rest -> do
    (name, params) <- liftToks hdr rest ruleHead
    (body, ls') <- closedBody hdr ls
    pure (SRule name params body, ls')
  _ -> Left (llNumber hdr)
  where
    eachHead = do
      a <- identName
      peek >>= \case
        Just (TSym ",") -> do
          advance
          b <- identName
          when (a == b) failP
          keyword "in"
          e <- exprP
          pure (Just a, b, e)
        _ -> do
          keyword "in"
          e <- exprP
          pure (Nothing, a, e)
    ruleHead = do
      name <- identName
      sym "("
      params <- commaList ")" paramP
      let names = [n | Param n _ <- params]
      when (length (nub names) /= length names) failP
      checkDefaults False params
      pure (name, params)
    paramP = do
      n <- identName
      peek >>= \case
        Just (TSym "=") -> advance >> Param n . Just <$> exprP
        _ -> pure (Param n Nothing)
    checkDefaults _ [] = pure ()
    checkDefaults seen (Param _ d : r) = case d of
      Just _ -> checkDefaults True r
      Nothing -> if seen then failP else checkDefaults seen r

-- | Parse a body that must be closed by a bare @}@.
closedBody :: LogicalLine -> [LogicalLine] -> Either Int ([Stmt], [LogicalLine])
closedBody hdr ls = do
  (body, rest) <- parseStmts ls
  case rest of
    Nothing -> Left (llNumber hdr)
    Just (t, ls') -> case llTokens t of
      [TSym "}"] -> Right (body, ls')
      _ -> Left (llNumber t)

-- | Parse the remainder of a @when@ chain after a branch's header.
whenChain
  :: LogicalLine -> [(Expr, [Stmt])] -> Expr -> [LogicalLine] -> Either Int (Stmt, [LogicalLine])
whenChain hdr done cond ls = do
  (body, rest) <- parseStmts ls
  let branches = done ++ [(cond, body)]
  case rest of
    Nothing -> Left (llNumber hdr)
    Just (t, ls') -> case llTokens t of
      [TSym "}"] -> Right (SWhen branches Nothing, ls')
      [TSym "}", TIdent "otherwise", TSym "{"] -> do
        (ob, rest') <- parseStmts ls'
        case rest' of
          Nothing -> Left (llNumber t)
          Just (t2, ls'') -> case llTokens t2 of
            [TSym "}"] -> Right (SWhen branches (Just ob), ls'')
            _ -> Left (llNumber t2)
      TSym "}" : TIdent "elsewhen" : more
        | Just (TSym "{") <- lastMay more -> do
            c <- liftToks t (init more) exprP
            whenChain t branches c ls'
      _ -> Left (llNumber t)

parseStepBody :: LogicalLine -> [LogicalLine] -> Either Int ([StepField], [LogicalLine])
parseStepBody hdr = go []
  where
    go _ [] = Left (llNumber hdr)
    go acc (l : ls) = case llTokens l of
      [TSym "}"] -> Right (reverse acc, ls)
      TSym "}" : _ -> Left (llNumber l)
      _ -> do
        f <- liftLine l fieldP
        go (f : acc) ls
    fieldP = do
      kw <- identAny
      case kw of
        "out" -> FOut <$> exprP
        "in" -> FIn <$> exprP
        "after" -> FAfter <$> exprP
        "cost" -> FCost <$> exprP
        "depfile" -> FDepfile <$> exprP
        "cmd" -> do
          name <- identAny
          sym "("
          FCmd name <$> commaList ")" exprP
        _ -> failP
