{-# LANGUAGE OverloadedStrings #-}
-- | Parsing: turns a template source into a checked 'Template'.
module Template.Parser
  ( parseTemplate
  , parseExpression
  , knownFilters
  ) where

import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import Template.Error
import Template.Lexer
import Template.Syntax

-- | The names of the supported filters.
knownFilters :: [Text]
knownFilters =
  [ "upper", "lower", "trim", "escape", "replace", "length", "int"
  , "join", "first", "last", "reverse", "sort", "default" ]

keywords :: [Text]
keywords = ["and", "or", "not", "in", "is", "true", "false", "none"]

-- | Lex, parse and check a template: syntax errors are reported first,
-- then unknown filter names.
parseTemplate :: Text -> Either ErrorKind Template
parseTemplate src = do
  items <- lexTemplate src
  (tpl, _) <- runPM (parseRoot items) (PState Map.empty False)
  if all (`elem` knownFilters) (templateFilters tpl)
    then Right tpl
    else Left ErrFilter

-- | Parse a standalone expression.
parseExpression :: Text -> Either ErrorKind Expr
parseExpression t = lexExpression t >>= \toks -> runWhole expr toks

----------------------------------------------------------------------
-- Expression parser

newtype P a = P { runP :: [Tok] -> Either ErrorKind (a, [Tok]) }

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
    Right (a, r) -> runP (f a) r

failP :: P a
failP = P $ \_ -> Left ErrSyntax

peek :: P (Maybe Tok)
peek = P $ \ts -> Right (case ts of { [] -> Nothing; (t : _) -> Just t }, ts)

peek2 :: P (Maybe Tok)
peek2 = P $ \ts -> Right (case ts of { (_ : t : _) -> Just t; _ -> Nothing }, ts)

advance :: P ()
advance = P $ \ts -> case ts of
  [] -> Left ErrSyntax
  (_ : r) -> Right ((), r)

-- Run a parser and require that all tokens are consumed.
runWhole :: P a -> [Tok] -> Either ErrorKind a
runWhole p ts = case runP p ts of
  Right (a, []) -> Right a
  Right _ -> Left ErrSyntax
  Left e -> Left e

isOp :: Text -> Maybe Tok -> Bool
isOp o (Just (TOp o')) = o == o'
isOp _ _ = False

isKw :: Text -> Maybe Tok -> Bool
isKw k (Just (TName n)) = k == n
isKw _ _ = False

expectOp :: Text -> P ()
expectOp o = peek >>= \t -> if isOp o t then advance else failP

-- A non-keyword name.
identifier :: P Text
identifier = peek >>= \t -> case t of
  Just (TName n) | n `notElem` keywords -> advance >> pure n
  _ -> failP

-- Any name (used after @.@ and @|@).
anyName :: P Text
anyName = peek >>= \t -> case t of
  Just (TName n) -> advance >> pure n
  _ -> failP

expr :: P Expr
expr = orE

orE :: P Expr
orE = andE >>= loop
  where
    loop l = peek >>= \t ->
      if isKw "or" t then advance >> andE >>= loop . EOr l else pure l

andE :: P Expr
andE = notE >>= loop
  where
    loop l = peek >>= \t ->
      if isKw "and" t then advance >> notE >>= loop . EAnd l else pure l

notE :: P Expr
notE = peek >>= \t ->
  if isKw "not" t then advance >> ENot <$> notE else compareE

compareE :: P Expr
compareE = do
  first <- additive
  rest <- loop
  pure (if null rest then first else ECompare first rest)
  where
    loop = do
      mop <- cmpOp
      case mop of
        Nothing -> pure []
        Just op -> do
          r <- additive
          ((op, r) :) <$> loop
    cmpOp = do
      t <- peek
      t2 <- peek2
      case t of
        Just (TOp o) | Just op <- lookup o table -> advance >> pure (Just op)
        Just (TName "in") -> advance >> pure (Just In)
        Just (TName "not") | isKw "in" t2 -> advance >> advance >> pure (Just NotIn)
        _ -> pure Nothing
    table = [("==", Eq), ("!=", Ne), ("<", Lt), ("<=", Le), (">", Gt), (">=", Ge)]

-- Left-associative binary operator level.
binLevel :: [(Text, BinOp)] -> P Expr -> P Expr
binLevel ops next = next >>= loop
  where
    loop l = peek >>= \t -> case t of
      Just (TOp o) | Just op <- lookup o ops -> advance >> next >>= loop . EBin op l
      _ -> pure l

additive, concatE, term, power :: P Expr
additive = binLevel [("+", Add), ("-", Sub)] concatE
concatE = binLevel [("~", Concat)] term
term = binLevel [("*", Mul), ("/", Div), ("//", FloorDiv), ("%", Mod)] power
power = binLevel [("**", Pow)] filtered

filtered :: P Expr
filtered = unary >>= loop
  where
    loop e = peek >>= \t -> case t of
      Just (TOp "|") -> do
        advance
        name <- anyName
        t' <- peek
        args <- if isOp "(" t' then advance >> argList else pure []
        loop (EFilter e name args)
      Just (TName "is") -> do
        advance
        t' <- peek
        neg <- if isKw "not" t' then advance >> pure True else pure False
        t'' <- peek
        if isKw "defined" t''
          then do
            advance
            let d = EIsDefined e
            loop (if neg then ENot d else d)
          else failP
      _ -> pure e

-- Comma-separated expressions up to and including the closing paren.
argList :: P [Expr]
argList = peek >>= \t ->
  if isOp ")" t then advance >> pure [] else go
  where
    go = do
      e <- expr
      t <- peek
      if isOp "," t then advance >> (e :) <$> go
      else if isOp ")" t then advance >> pure [e]
      else failP

unary :: P Expr
unary = peek >>= \t ->
  if isOp "-" t then advance >> ENeg <$> unary else postfix

postfix :: P Expr
postfix = primary >>= loop
  where
    loop e = peek >>= \t -> case t of
      Just (TOp ".") -> do
        advance
        n <- anyName
        loop (EIndex e (EStr n))
      Just (TOp "[") -> do
        advance
        k <- expr
        expectOp "]"
        loop (EIndex e k)
      Just (TOp "(") -> do
        advance
        (pos, kws) <- callArgs
        loop (ECall e pos kws)
      _ -> pure e

-- Call arguments after the opening paren: positional first, then keywords.
callArgs :: P ([Expr], [(Text, Expr)])
callArgs = peek >>= \t ->
  if isOp ")" t then advance >> pure ([], []) else go [] []
  where
    go pos kws = do
      t <- peek
      t2 <- peek2
      (pos', kws') <- case (t, t2) of
        (Just (TName n), Just (TOp "="))
          | n `notElem` keywords -> do
              advance >> advance
              e <- expr
              if n `elem` map fst kws then failP else pure (pos, kws ++ [(n, e)])
        _ -> do
          e <- expr
          if null kws then pure (pos ++ [e], kws) else failP
      t' <- peek
      if isOp "," t' then advance >> go pos' kws'
      else if isOp ")" t' then advance >> pure (pos', kws')
      else failP

primary :: P Expr
primary = peek >>= \t -> case t of
  Just (TInt n) -> advance >> pure (EInt n)
  Just (TFloat d) -> advance >> pure (EFloat d)
  Just (TStr s) -> advance >> pure (EStr s)
  Just (TName "true") -> advance >> pure (EBool True)
  Just (TName "false") -> advance >> pure (EBool False)
  Just (TName "none") -> advance >> pure ENone
  Just (TName n) | n `notElem` keywords -> advance >> pure (EVar n)
  Just (TOp "[") -> advance >> listLit
  Just (TOp "(") -> do
    advance
    e <- expr
    expectOp ")"
    pure e
  _ -> failP

listLit :: P Expr
listLit = EList <$> (peek >>= \t ->
  if isOp "]" t then advance >> pure [] else go)
  where
    go = do
      e <- expr
      t <- peek
      if isOp "," t then advance >> (e :) <$> go
      else if isOp "]" t then advance >> pure [e]
      else failP

----------------------------------------------------------------------
-- Statement tags

data Tag
  = TagIf Expr
  | TagElif Expr
  | TagElse
  | TagEndif
  | TagFor Text Expr
  | TagEndfor
  | TagSet Text Expr
  | TagMacro Text [Param]
  | TagEndmacro
  | TagInclude Expr
  | TagExtends Expr
  | TagBlock Text
  | TagEndblock (Maybe Text)

parseTag :: [Tok] -> Either ErrorKind Tag
parseTag toks = case toks of
  (TName kw : rest) -> case kw of
    "if" -> TagIf <$> runWhole expr rest
    "elif" -> TagElif <$> runWhole expr rest
    "else" -> bare TagElse rest
    "endif" -> bare TagEndif rest
    "endfor" -> bare TagEndfor rest
    "endmacro" -> bare TagEndmacro rest
    "for" -> runWhole (TagFor <$> identifier <* keyword "in" <*> expr) rest
    "set" -> runWhole (TagSet <$> identifier <* expectOp "=" <*> expr) rest
    "macro" -> runWhole macroHead rest
    "include" -> TagInclude <$> runWhole expr rest
    "extends" -> TagExtends <$> runWhole expr rest
    "block" -> runWhole (TagBlock <$> identifier) rest
    "endblock" -> case rest of
      [] -> Right (TagEndblock Nothing)
      _ -> runWhole (TagEndblock . Just <$> identifier) rest
    _ -> Left ErrSyntax
  _ -> Left ErrSyntax
  where
    bare tag [] = Right tag
    bare _ _ = Left ErrSyntax
    keyword k = peek >>= \t -> if isKw k t then advance else failP

macroHead :: P Tag
macroHead = do
  name <- identifier
  expectOp "("
  params <- paramList
  let names = [n | Param n _ <- params]
  if length (nub names) /= length names then failP else pure (TagMacro name params)

paramList :: P [Param]
paramList = peek >>= \t ->
  if isOp ")" t then advance >> pure [] else go
  where
    go = do
      n <- identifier
      t <- peek
      def <- if isOp "=" t then advance >> Just <$> expr else pure Nothing
      let p = Param n def
      t' <- peek
      if isOp "," t' then advance >> (p :) <$> go
      else if isOp ")" t' then advance >> pure [p]
      else failP

----------------------------------------------------------------------
-- Block structure

data PState = PState
  { psBlocks  :: Map Text [Stmt]
  , psExtends :: Bool
  }

newtype PM a = PM { runPM :: PState -> Either ErrorKind (a, PState) }

instance Functor PM where
  fmap f (PM g) = PM $ \s -> case g s of
    Left e -> Left e
    Right (a, s') -> Right (f a, s')

instance Applicative PM where
  pure a = PM $ \s -> Right (a, s)
  PM f <*> PM g = PM $ \s -> case f s of
    Left e -> Left e
    Right (h, s') -> case g s' of
      Left e -> Left e
      Right (a, s'') -> Right (h a, s'')

instance Monad PM where
  PM g >>= f = PM $ \s -> case g s of
    Left e -> Left e
    Right (a, s') -> runPM (f a) s'

liftE :: Either ErrorKind a -> PM a
liftE r = PM $ \s -> fmap (\a -> (a, s)) r

getS :: PM PState
getS = PM $ \s -> Right (s, s)

putS :: PState -> PM ()
putS s = PM $ \_ -> Right ((), s)

synErr :: PM a
synErr = liftE (Left ErrSyntax)

-- What ended a statement list.
data Stop
  = StopEof
  | StopElif Expr
  | StopElse
  | StopEndif
  | StopEndfor
  | StopEndmacro
  | StopEndblock (Maybe Text)

parseRoot :: [Item] -> PM Template
parseRoot items = do
  (body, stop, _) <- parseBody True items
  case stop of
    StopEof -> do
      st <- getS
      pure (Template body (psBlocks st))
    _ -> synErr

-- Parse statements until a terminating tag or the end of the items.
parseBody :: Bool -> [Item] -> PM ([Stmt], Stop, [Item])
parseBody top = go []
  where
    done acc stop rest = pure (reverse acc, stop, rest)
    go acc [] = done acc StopEof []
    go acc (it : rest) = case it of
      ItemText t -> go (SText t : acc) rest
      ItemPrint toks -> do
        e <- liftE (runWhole expr toks)
        go (SPrint e : acc) rest
      ItemTag toks -> do
        tag <- liftE (parseTag toks)
        case tag of
          TagElif e -> done acc (StopElif e) rest
          TagElse -> done acc StopElse rest
          TagEndif -> done acc StopEndif rest
          TagEndfor -> done acc StopEndfor rest
          TagEndmacro -> done acc StopEndmacro rest
          TagEndblock n -> done acc (StopEndblock n) rest
          TagIf c -> do
            (s, rest') <- parseIf c rest
            go (s : acc) rest'
          TagFor v e -> do
            (body, stop, rest1) <- parseBody False rest
            case stop of
              StopEndfor -> go (SFor v e body [] : acc) rest1
              StopElse -> do
                (els, stop2, rest2) <- parseBody False rest1
                case stop2 of
                  StopEndfor -> go (SFor v e body els : acc) rest2
                  _ -> synErr
              _ -> synErr
          TagSet n e -> go (SSet n e : acc) rest
          TagMacro n ps -> do
            (body, stop, rest1) <- parseBody False rest
            case stop of
              StopEndmacro -> go (SMacro n ps body : acc) rest1
              _ -> synErr
          TagInclude e -> go (SInclude e : acc) rest
          TagExtends e -> do
            st <- getS
            if not top || psExtends st then synErr else do
              putS st { psExtends = True }
              go (SExtends e : acc) rest
          TagBlock n -> do
            (body, stop, rest1) <- parseBody False rest
            case stop of
              StopEndblock mn | maybe True (== n) mn -> do
                st <- getS
                if Map.member n (psBlocks st) then synErr else do
                  putS st { psBlocks = Map.insert n body (psBlocks st) }
                  go (SBlock n : acc) rest1
              _ -> synErr

-- Parse the rest of an @if@ whose first condition has been read.
parseIf :: Expr -> [Item] -> PM (Stmt, [Item])
parseIf cond0 = branches [] cond0
  where
    branches acc cond items = do
      (body, stop, rest) <- parseBody False items
      let acc' = (cond, body) : acc
      case stop of
        StopEndif -> pure (SIf (reverse acc') [], rest)
        StopElif c -> branches acc' c rest
        StopElse -> do
          (els, stop2, rest2) <- parseBody False rest
          case stop2 of
            StopEndif -> pure (SIf (reverse acc') els, rest2)
            _ -> synErr
        _ -> synErr

----------------------------------------------------------------------
-- Filter names used by a template

templateFilters :: Template -> [Text]
templateFilters (Template body blocks) =
  concatMap stmtFilters body ++ concatMap (concatMap stmtFilters) (Map.elems blocks)

stmtFilters :: Stmt -> [Text]
stmtFilters s = case s of
  SText _ -> []
  SPrint e -> exprFilters e
  SIf bs els -> concat [exprFilters c ++ concatMap stmtFilters b | (c, b) <- bs]
                  ++ concatMap stmtFilters els
  SFor _ e b els -> exprFilters e ++ concatMap stmtFilters b ++ concatMap stmtFilters els
  SSet _ e -> exprFilters e
  SMacro _ ps b -> concat [exprFilters d | Param _ md <- ps, Just d <- [md]]
                     ++ concatMap stmtFilters b
  SInclude e -> exprFilters e
  SExtends e -> exprFilters e
  SBlock _ -> []

exprFilters :: Expr -> [Text]
exprFilters e = case e of
  EList es -> concatMap exprFilters es
  EIndex a b -> exprFilters a ++ exprFilters b
  ENeg a -> exprFilters a
  ENot a -> exprFilters a
  EBin _ a b -> exprFilters a ++ exprFilters b
  EAnd a b -> exprFilters a ++ exprFilters b
  EOr a b -> exprFilters a ++ exprFilters b
  ECompare a rest -> exprFilters a ++ concatMap (exprFilters . snd) rest
  EFilter a n args -> n : exprFilters a ++ concatMap exprFilters args
  EIsDefined a -> exprFilters a
  ECall f pos kws -> exprFilters f ++ concatMap exprFilters pos ++ concatMap (exprFilters . snd) kws
  _ -> []
