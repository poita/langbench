{-# LANGUAGE OverloadedStrings #-}

-- | Parsing template source into a 'Template'.
module Sitegen.Template.Parser
  ( parseTemplate
  , knownFilters
  ) where

import Control.Monad (unless, when)
import Control.Monad.State.Strict
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import Sitegen.Template.Lexer
import Sitegen.Template.Syntax

-- | The names of the built-in filters.
knownFilters :: [Text]
knownFilters =
  [ "upper", "lower", "trim", "escape", "replace", "length", "int", "join"
  , "first", "last", "reverse", "sort", "default" ]

-- | Parse and check a template: lexing and parsing errors are reported as
-- 'SyntaxError', then any unknown filter as 'FilterError'.
parseTemplate :: Text -> Either ErrorKind Template
parseTemplate src = do
  items <- maybe (Left SyntaxError) Right (lexTemplate src)
  (body, st) <- maybe (Left SyntaxError) Right (runStateT (parseTop) (PState items Map.empty False))
  let tpl = Template body (psBlocks st)
  if all (`elem` knownFilters) (nub (nodesFilters body))
    then Right tpl
    else Left FilterError

-- ---------------------------------------------------------------------------
-- Filter collection

nodesFilters :: [Node] -> [Text]
nodesFilters = concatMap nodeFilters

nodeFilters :: Node -> [Text]
nodeFilters n = case n of
  NText _ -> []
  NPrint e -> exprFilters e
  NIf bs els -> concat [exprFilters c ++ nodesFilters b | (c, b) <- bs] ++ nodesFilters els
  NFor _ e b els -> exprFilters e ++ nodesFilters b ++ nodesFilters els
  NSet _ e -> exprFilters e
  NMacro _ ps b -> concat [exprFilters e | (_, Just e) <- ps] ++ nodesFilters b
  NInclude e -> exprFilters e
  NExtends e -> exprFilters e
  NBlock _ b -> nodesFilters b

exprFilters :: Expr -> [Text]
exprFilters e = case e of
  EList xs -> concatMap exprFilters xs
  ENeg x -> exprFilters x
  ENot x -> exprFilters x
  EBin _ a b -> exprFilters a ++ exprFilters b
  EAnd a b -> exprFilters a ++ exprFilters b
  EOr a b -> exprFilters a ++ exprFilters b
  ECompare a rest -> exprFilters a ++ concatMap (exprFilters . snd) rest
  EFilter x name args -> name : exprFilters x ++ concatMap exprFilters args
  EIsDefined _ x -> exprFilters x
  EAttr x _ -> exprFilters x
  EIndex a b -> exprFilters a ++ exprFilters b
  ECall f args kws -> exprFilters f ++ concatMap exprFilters args ++ concatMap (exprFilters . snd) kws
  _ -> []

-- ---------------------------------------------------------------------------
-- Statement parser

data PState = PState
  { psItems :: [Item]
  , psBlocks :: Map.Map Text [Node]
  , psExtends :: Bool
  }

type P = StateT PState Maybe

data Stop = StopEOF | StopTag Text [Token]

parseTop :: P [Node]
parseTop = fst <$> parseNodes True []

setItems :: [Item] -> P ()
setItems is = modify' (\s -> s {psItems = is})

keywords :: [Text]
keywords = ["and", "or", "not", "in", "is", "true", "false", "none"]

parseNodes :: Bool -> [Text] -> P ([Node], Stop)
parseNodes top terms = loop []
  where
    loop acc = do
      items <- gets psItems
      case items of
        [] -> if null terms then pure (reverse acc, StopEOF) else lift Nothing
        (IText t : r) -> setItems r >> loop (NText t : acc)
        (IPrint toks : r) -> do
          setItems r
          e <- lift (exprAll toks)
          loop (NPrint e : acc)
        (IStmt toks : r) -> do
          setItems r
          case toks of
            (TName kw : rest)
              | kw `elem` terms -> pure (reverse acc, StopTag kw rest)
              | otherwise -> do
                  n <- parseStmt top kw rest
                  loop (n : acc)
            _ -> lift Nothing

parseStmt :: Bool -> Text -> [Token] -> P Node
parseStmt top kw rest = case kw of
  "if" -> do
    c <- lift (exprAll rest)
    parseIf [] c
  "for" -> case rest of
    (TName v : TName "in" : more) | v `notElem` keywords -> do
      e <- lift (exprAll more)
      (body, stop) <- parseNodes False ["else", "endfor"]
      case stop of
        StopTag "endfor" [] -> pure (NFor v e body [])
        StopTag "else" [] -> do
          (els, stop2) <- parseNodes False ["endfor"]
          case stop2 of
            StopTag "endfor" [] -> pure (NFor v e body els)
            _ -> lift Nothing
        _ -> lift Nothing
    _ -> lift Nothing
  "set" -> case rest of
    (TName v : TOp "=" : more) | v `notElem` keywords -> NSet v <$> lift (exprAll more)
    _ -> lift Nothing
  "macro" -> case rest of
    (TName name : TOp "(" : more) | name `notElem` keywords -> do
      params <- lift (macroParams more)
      (body, stop) <- parseNodes False ["endmacro"]
      case stop of
        StopTag "endmacro" [] -> pure (NMacro name params body)
        _ -> lift Nothing
    _ -> lift Nothing
  "include" -> NInclude <$> lift (exprAll rest)
  "extends" -> do
    seen <- gets psExtends
    when (not top || seen) $ lift Nothing
    modify' (\s -> s {psExtends = True})
    NExtends <$> lift (exprAll rest)
  "block" -> case rest of
    [TName name] -> do
      (body, stop) <- parseNodes False ["endblock"]
      case stop of
        StopTag "endblock" more
          | null more || more == [TName name] -> do
              blocks <- gets psBlocks
              when (Map.member name blocks) $ lift Nothing
              modify' (\s -> s {psBlocks = Map.insert name body blocks})
              pure (NBlock name body)
        _ -> lift Nothing
    _ -> lift Nothing
  _ -> lift Nothing
  where
    parseIf acc c = do
      (body, stop) <- parseNodes False ["elif", "else", "endif"]
      let acc' = acc ++ [(c, body)]
      case stop of
        StopTag "endif" [] -> pure (NIf acc' [])
        StopTag "elif" toks -> do
          c' <- lift (exprAll toks)
          parseIf acc' c'
        StopTag "else" [] -> do
          (els, stop2) <- parseNodes False ["endif"]
          case stop2 of
            StopTag "endif" [] -> pure (NIf acc' els)
            _ -> lift Nothing
        _ -> lift Nothing

-- | Parameters after the opening parenthesis of a macro definition.
macroParams :: [Token] -> Maybe [(Text, Maybe Expr)]
macroParams toks = case toks of
  (TOp ")" : []) -> Just []
  _ -> do
    (ps, rest) <- runStateT params toks
    unless (null rest) Nothing
    let names = map fst ps
    unless (length (nub names) == length names) Nothing
    Just ps
  where
    params = do
      p <- param
      t <- gets headTok
      case t of
        Just (TOp ",") -> modify' (drop 1) >> ((p :) <$> params)
        Just (TOp ")") -> modify' (drop 1) >> pure [p]
        _ -> lift Nothing
    param = do
      t <- gets headTok
      case t of
        Just (TName n) | n `notElem` keywords -> do
          modify' (drop 1)
          t2 <- gets headTok
          case t2 of
            Just (TOp "=") -> do
              modify' (drop 1)
              e <- pExpr
              pure (n, Just e)
            _ -> pure (n, Nothing)
        _ -> lift Nothing

-- ---------------------------------------------------------------------------
-- Expression parser

type E = StateT [Token] Maybe

headTok :: [Token] -> Maybe Token
headTok [] = Nothing
headTok (t : _) = Just t

-- | Parse an expression that must use all the tokens.
exprAll :: [Token] -> Maybe Expr
exprAll toks = do
  (e, rest) <- runStateT pExpr toks
  if null rest then Just e else Nothing

peek :: E (Maybe Token)
peek = gets headTok

advance :: E ()
advance = modify' (drop 1)

isOp :: Text -> E Bool
isOp o = (== Just (TOp o)) <$> peek

isKw :: Text -> E Bool
isKw k = (== Just (TName k)) <$> peek

expectOp :: Text -> E ()
expectOp o = do
  b <- isOp o
  if b then advance else lift Nothing

pExpr :: E Expr
pExpr = pOr

pOr :: E Expr
pOr = pAnd >>= loop
  where
    loop l = do
      b <- isKw "or"
      if b then advance >> pAnd >>= loop . EOr l else pure l

pAnd :: E Expr
pAnd = pNot >>= loop
  where
    loop l = do
      b <- isKw "and"
      if b then advance >> pNot >>= loop . EAnd l else pure l

pNot :: E Expr
pNot = do
  b <- isKw "not"
  if b then advance >> (ENot <$> pNot) else pCompare

pCompare :: E Expr
pCompare = do
  l <- pAdditive
  rest <- loop
  pure (if null rest then l else ECompare l rest)
  where
    loop = do
      t <- gets id
      case t of
        (TOp o : _) | Just op <- lookup o cmpOps -> advance >> next op
        (TName "in" : _) -> advance >> next In
        (TName "not" : TName "in" : _) -> advance >> advance >> next NotIn
        _ -> pure []
    next op = do
      r <- pAdditive
      ((op, r) :) <$> loop
    cmpOps = [("==", Eq), ("!=", Ne), ("<", Lt), ("<=", Le), (">", Gt), (">=", Ge)]

binLevel :: [(Text, BinOp)] -> E Expr -> E Expr
binLevel ops sub = sub >>= loop
  where
    loop l = do
      t <- peek
      case t of
        Just (TOp o) | Just op <- lookup o ops -> do
          advance
          r <- sub
          loop (EBin op l r)
        _ -> pure l

pAdditive, pConcat, pTerm, pPower :: E Expr
pAdditive = binLevel [("+", Add), ("-", Sub)] pConcat
pConcat = binLevel [("~", Concat)] pTerm
pTerm = binLevel [("*", Mul), ("/", Div), ("//", FloorDiv), ("%", Mod)] pPower
pPower = binLevel [("**", Pow)] pFiltered

pFiltered :: E Expr
pFiltered = pUnary >>= loop
  where
    loop e = do
      t <- gets id
      case t of
        (TOp "|" : TName name : _) -> do
          advance >> advance
          open <- isOp "("
          args <-
            if open
              then advance >> pArgs
              else pure []
          loop (EFilter e name args)
        (TName "is" : TName "not" : TName "defined" : _) ->
          advance >> advance >> advance >> loop (EIsDefined True e)
        (TName "is" : TName "defined" : _) ->
          advance >> advance >> loop (EIsDefined False e)
        (TName "is" : _) -> lift Nothing
        (TOp "|" : _) -> lift Nothing
        _ -> pure e

-- | Positional filter arguments up to the closing parenthesis.
pArgs :: E [Expr]
pArgs = do
  close <- isOp ")"
  if close
    then advance >> pure []
    else go
  where
    go = do
      e <- pExpr
      t <- peek
      case t of
        Just (TOp ",") -> advance >> (e :) <$> go
        Just (TOp ")") -> advance >> pure [e]
        _ -> lift Nothing

pUnary :: E Expr
pUnary = do
  b <- isOp "-"
  if b then advance >> (ENeg <$> pUnary) else pPostfix

pPostfix :: E Expr
pPostfix = pPrimary >>= loop
  where
    loop e = do
      t <- gets id
      case t of
        (TOp "." : TName n : _) -> advance >> advance >> loop (EAttr e n)
        (TOp "." : _) -> lift Nothing
        (TOp "[" : _) -> do
          advance
          i <- pExpr
          expectOp "]"
          loop (EIndex e i)
        (TOp "(" : _) -> do
          advance
          (args, kws) <- pCallArgs
          loop (ECall e args kws)
        _ -> pure e

pCallArgs :: E ([Expr], [(Text, Expr)])
pCallArgs = do
  close <- isOp ")"
  if close then advance >> pure ([], []) else go [] []
  where
    go pos kws = do
      t <- gets id
      (pos', kws') <- case t of
        (TName n : TOp "=" : _) -> do
          advance >> advance
          e <- pExpr
          when (n `elem` map fst kws) $ lift Nothing
          pure (pos, kws ++ [(n, e)])
        _ -> do
          unless (null kws) $ lift Nothing
          e <- pExpr
          pure (pos ++ [e], kws)
      t2 <- peek
      case t2 of
        Just (TOp ",") -> advance >> go pos' kws'
        Just (TOp ")") -> advance >> pure (pos', kws')
        _ -> lift Nothing

pPrimary :: E Expr
pPrimary = do
  t <- peek
  case t of
    Just (TInt n) -> advance >> pure (EInt n)
    Just (TFloat d) -> advance >> pure (EFloat d)
    Just (TString s) -> advance >> pure (EString s)
    Just (TName "true") -> advance >> pure (EBool True)
    Just (TName "false") -> advance >> pure (EBool False)
    Just (TName "none") -> advance >> pure ENone
    Just (TName n)
      | n `elem` keywords -> lift Nothing
      | otherwise -> advance >> pure (EName n)
    Just (TOp "[") -> do
      advance
      close <- isOp "]"
      if close
        then advance >> pure (EList [])
        else EList <$> items
    Just (TOp "(") -> do
      advance
      e <- pExpr
      expectOp ")"
      pure e
    _ -> lift Nothing
  where
    items = do
      e <- pExpr
      t <- peek
      case t of
        Just (TOp ",") -> advance >> (e :) <$> items
        Just (TOp "]") -> advance >> pure [e]
        _ -> lift Nothing
