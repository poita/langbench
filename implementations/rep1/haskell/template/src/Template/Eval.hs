{-# LANGUAGE OverloadedStrings #-}
-- | The tree-walking interpreter.
module Template.Eval
  ( renderIO
  ) where

import Control.Exception (evaluate, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T

import Template.Error
import Template.Filters
import Template.Ops
import Template.Parser
import Template.Syntax
import Template.Value

-- | State shared by a whole render.
data Env = Env
  { envSources :: Map Text Text
  , envCache   :: IORef (Map Text (Either ErrorKind Template))
  }

-- | State of one rendering of a template (the main one or one @include@).
data Ctx = Ctx
  { ctxChains :: IORef (Map Text [[Stmt]])  -- ^ block name -> bodies, most derived first
  , ctxScope  :: Scope                      -- ^ the template scope
  }

type Buf = IORef [Text]

-- | Everything a statement or expression needs while it runs.
data Frame = Frame
  { frEnv   :: Env
  , frCtx   :: Ctx
  , frScope :: Scope
  , frBuf   :: Buf
  }

failWith :: ErrorKind -> IO a
failWith = throwIO . EvalError

liftE :: Either ErrorKind a -> IO a
liftE = either failWith pure

-- | Render the named template, given the context members, the template
-- sources and the name of the template to render.
renderIO :: [(Text, Value)] -> [(Text, Text)] -> Text -> IO (Either ErrorKind Text)
renderIO context sources mainName = do
  cache <- newIORef Map.empty
  rootRef <- newIORef (Map.union (Map.fromList context) (Map.singleton "range" VRange))
  let root = Scope rootRef Nothing
      env = Env (Map.fromList sources) cache
  r <- try $ do
    tpl <- loadTemplate env mainName
    buf <- newBuf
    ctx <- newCtx tpl (Just root)
    runTemplate (Frame env ctx (ctxScope ctx) buf) tpl
    out <- readBuf buf
    evaluate out
  pure $ case r of
    Left (EvalError k) -> Left k
    Right t -> Right t

newBuf :: IO Buf
newBuf = newIORef []

readBuf :: Buf -> IO Text
readBuf b = T.concat . reverse <$> readIORef b

emit :: Frame -> Text -> IO ()
emit fr t = unless (T.null t) (modifyIORef' (frBuf fr) (t :))

newCtx :: Template -> Maybe Scope -> IO Ctx
newCtx tpl parent = do
  chains <- newIORef (Map.map (: []) (tplBlocks tpl))
  sc <- newScope parent
  pure (Ctx chains sc)

-- | Load (lex, parse, check) a template at most once.
loadTemplate :: Env -> Text -> IO Template
loadTemplate env name = do
  cache <- readIORef (envCache env)
  case Map.lookup name cache of
    Just r -> liftE r
    Nothing -> case Map.lookup name (envSources env) of
      Nothing -> failWith ErrTemplate
      Just src -> do
        let r = parseTemplate src
        modifyIORef' (envCache env) (Map.insert name r)
        liftE r

-- Run a template's top-level body, then its parent's if it extends one.
runTemplate :: Frame -> Template -> IO ()
runTemplate fr tpl = go (tplBody tpl)
  where
    go [] = pure ()
    go (SExtends e : rest) = do
      name <- evalTemplateName fr e
      parent <- loadTemplate (frEnv fr) name
      modifyIORef' (ctxChains (frCtx fr))
        (\m -> Map.unionWith (++) m (Map.map (: []) (tplBlocks parent)))
      skipping rest
      runTemplate fr parent
    go (s : rest) = execStmt fr s >> go rest
    -- After @extends@ only @set@ and @macro@ have any effect.
    skipping = mapM_ (\s -> case s of
      SSet {} -> execStmt fr s
      SMacro {} -> execStmt fr s
      _ -> pure ())

evalTemplateName :: Frame -> Expr -> IO Text
evalTemplateName fr e = do
  v <- evalExpr fr e
  case v of
    VStr t -> pure t
    VUndefined -> failWith ErrUndefined
    _ -> failWith ErrType

execStmts :: Frame -> [Stmt] -> IO ()
execStmts fr = mapM_ (execStmt fr)

execStmt :: Frame -> Stmt -> IO ()
execStmt fr stmt = case stmt of
  SText t -> emit fr t
  SPrint e -> do
    v <- evalExpr fr e
    t <- liftE (display v)
    emit fr t
  SIf branches els -> goIf branches els
  SFor name e body els -> do
    v <- evalExpr fr e
    when (isUndefined v) (failWith ErrUndefined)
    xs <- maybe (failWith ErrType) pure (sequenceView v)
    let n = Seq.length xs
    if n == 0
      then execStmts fr els
      else forM_ (zip [0 ..] (toList xs)) $ \(i, x) -> do
        sc <- newScope (Just (frScope fr))
        bindVar sc name x
        bindVar sc "loop" (VDict (dictFromList
          [ ("index", VInt (i + 1)), ("index0", VInt i)
          , ("first", VBool (i == 0)), ("last", VBool (i == fromIntegral n - 1))
          , ("length", VInt (fromIntegral n)) ]))
        execStmts fr { frScope = sc } body
  SSet name e -> do
    v <- evalExpr fr e
    bindVar (frScope fr) name v
  SMacro name params body ->
    bindVar (frScope fr) name (VMacro (Macro name params body (frScope fr)))
  SInclude e -> do
    name <- evalTemplateName fr e
    tpl <- loadTemplate (frEnv fr) name
    ctx <- newCtx tpl (Just (frScope fr))
    runTemplate fr { frCtx = ctx, frScope = ctxScope ctx } tpl
  SExtends _ -> pure ()   -- handled by 'runTemplate'; the parser allows it only at top level
  SBlock name -> do
    chains <- readIORef (ctxChains (frCtx fr))
    case Map.lookup name chains of
      Just chain@(_ : _) -> renderChain fr chain (frBuf fr)
      _ -> pure ()
  where
    goIf [] els = execStmts fr els
    goIf ((c, body) : more) els = do
      v <- evalExpr fr c
      b <- liftE (truthy v)
      if b then execStmts fr body else goIf more els

-- Render the first body of a block chain into a buffer; @super()@ renders
-- the rest of the chain.
renderChain :: Frame -> [[Stmt]] -> Buf -> IO ()
renderChain _ [] _ = failWith ErrUndefined
renderChain fr (body : rest) buf = do
  sc <- newScope (Just (ctxScope (frCtx fr)))
  bindVar sc "super" $ VSuper $ do
    b <- newBuf
    renderChain fr rest b
    readBuf b
  execStmts fr { frScope = sc, frBuf = buf } body

evalExpr :: Frame -> Expr -> IO Value
evalExpr fr expression = case expression of
  EInt n -> pure (VInt n)
  EFloat d -> pure (VFloat d)
  EStr t -> pure (VStr t)
  EBool b -> pure (VBool b)
  ENone -> pure VNone
  EVar n -> lookupVar (frScope fr) n
  EList es -> VList . Seq.fromList <$> mapM (evalExpr fr) es
  EIndex a k -> do
    av <- evalExpr fr a
    kv <- evalExpr fr k
    liftE (subscript av kv)
  ENeg a -> evalExpr fr a >>= liftE . negateValue
  ENot a -> do
    v <- evalExpr fr a
    VBool . not <$> liftE (truthy v)
  EBin op a b -> do
    x <- evalExpr fr a
    y <- evalExpr fr b
    liftE (binary op x y)
  EAnd a b -> do
    x <- evalExpr fr a
    t <- liftE (truthy x)
    if t then evalExpr fr b else pure x
  EOr a b -> do
    x <- evalExpr fr a
    t <- liftE (truthy x)
    if t then pure x else evalExpr fr b
  ECompare a rest -> do
    x <- evalExpr fr a
    VBool <$> chain x rest
  EFilter a name args -> do
    v <- evalExpr fr a
    avs <- mapM (evalExpr fr) args
    liftE (applyFilter name v avs)
  EIsDefined a -> VBool . not . isUndefined <$> evalExpr fr a
  ECall f pos kws -> do
    fv <- evalExpr fr f
    pvs <- mapM (evalExpr fr) pos
    kvs <- forM kws $ \(k, e) -> (,) k <$> evalExpr fr e
    call fr fv pvs kvs
  where
    chain _ [] = pure True
    chain l ((op, e) : more) = do
      r <- evalExpr fr e
      ok <- liftE (compareValues op l r)
      if ok then chain r more else pure False

-- Attribute and subscript access.
subscript :: Value -> Value -> Either ErrorKind Value
subscript a k
  | isUndefined a || isUndefined k = Left ErrUndefined
  | otherwise = Right $ case (a, k) of
      (VDict d, VStr key) -> maybe VUndefined id (dictLookup key d)
      (VList xs, _) | Just (NI i) <- asNumber k ->
        let n = fromIntegral (Seq.length xs)
            j = if i < 0 then i + n else i
        in if j < 0 || j >= n then VUndefined else maybe VUndefined id (Seq.lookup (fromInteger j) xs)
      (VStr t, _) | Just (NI i) <- asNumber k ->
        let n = fromIntegral (T.length t)
            j = if i < 0 then i + n else i
        in if j < 0 || j >= n then VUndefined else VStr (T.take 1 (T.drop (fromInteger j) t))
      _ -> VUndefined

call :: Frame -> Value -> [Value] -> [(Text, Value)] -> IO Value
call fr fv pos kws = case fv of
  VMacro m -> callMacro fr m pos kws
  VRange -> do
    unless (null kws) (failWith ErrType)
    let n = length pos
    when (n < 1 || n > 3) (failWith ErrType)
    ints <- forM pos $ \v -> case v of
      VUndefined -> failWith ErrUndefined
      _ -> case asNumber v of
        Just (NI i) -> pure i
        _ -> failWith ErrType
    let (start, stop, step) = case ints of
          [s] -> (0, s, 1)
          [a, b] -> (a, b, 1)
          [a, b, c] -> (a, b, c)
          _ -> (0, 0, 1)
    when (step == 0) (failWith ErrType)
    let xs = if step > 0 then takeWhile (< stop) [start, start + step ..]
                         else takeWhile (> stop) [start, start + step ..]
    pure (VList (Seq.fromList (map VInt xs)))
  VSuper act -> do
    unless (null pos && null kws) (failWith ErrType)
    VStr <$> act
  VUndefined -> failWith ErrUndefined
  _ -> failWith ErrType

callMacro :: Frame -> Macro -> [Value] -> [(Text, Value)] -> IO Value
callMacro fr m pos kws = do
  sc <- newScope (Just (macroScope m))
  let params = [p | Param p _ <- macroParams m]
  when (length pos > length params) (failWith ErrType)
  let bound = zip params pos
  forM_ bound $ \(p, v) -> bindVar sc p v
  forM_ kws $ \(k, v) -> do
    when (k `notElem` params || k `elem` map fst bound) (failWith ErrType)
    bindVar sc k v
  forM_ (macroParams m) $ \(Param p def) -> do
    vars <- readIORef (scopeVars sc)
    unless (Map.member p vars) $ do
      let inner = fr { frScope = sc }
      v <- maybe (pure VUndefined) (evalExpr inner) def
      bindVar sc p v
  buf <- newBuf
  execStmts fr { frScope = sc, frBuf = buf } (macroBody m)
  VStr <$> readBuf buf
