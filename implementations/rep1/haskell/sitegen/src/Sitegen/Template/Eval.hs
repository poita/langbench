{-# LANGUAGE OverloadedStrings #-}

-- | The tree-walking interpreter.
--
-- Scopes are mutable (a @set@ is visible to macros defined earlier in the
-- same scope), so evaluation runs in 'ST'. Values themselves are immutable
-- and shared; macros refer to their defining scope by an id registered in
-- the environment.
module Sitegen.Template.Eval
  ( Templates
  , mkTemplates
  , templateNames
  , renderTemplate
  ) where

import Control.Monad (forM, forM_, when, zipWithM_)
import Control.Monad.ST (ST, runST)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as Map
import qualified Data.Map.Lazy as ML
import qualified Data.Sequence as Seq
import Data.STRef
import Data.Text (Text)
import qualified Data.Text as T

import Sitegen.Template.Ops
import Sitegen.Template.Parser (parseTemplate)
import Sitegen.Template.Syntax
import Sitegen.Template.Value

-- | A set of named template sources. Each template is parsed (and its
-- filters checked) at most once, the first time it is needed, however many
-- times it is rendered.
newtype Templates = Templates (ML.Map Text (Either ErrorKind Template))

-- | Build a template set from @(name, source)@ pairs.
mkTemplates :: [(Text, Text)] -> Templates
mkTemplates srcs = Templates (ML.fromList [(n, parseTemplate s) | (n, s) <- srcs])

-- | The names of the templates in the set.
templateNames :: Templates -> [Text]
templateNames (Templates m) = ML.keys m

-- ---------------------------------------------------------------------------

type Eval s = ExceptT ErrorKind (ST s)

data Scope s = Scope
  { scId :: !Int
  , scVars :: !(STRef s (Map.Map Text Value))
  , scParent :: !(Maybe (Scope s))
  }

data Render s = Render
  { rScope :: Scope s
  , rChains :: STRef s (Map.Map Text [[Node]])
  }

data Env s = Env
  { eTemplates :: Templates
  , eRegistry :: STRef s (IM.IntMap (Scope s))
  , eCounter :: STRef s Int
  , eOut :: STRef s [Text]
  , eRender :: Maybe (Render s)
  }

st :: ST s a -> Eval s a
st = lift

throw :: ErrorKind -> Eval s a
throw = throwE

liftR :: Either ErrorKind a -> Eval s a
liftR = either throw pure

newScope :: Env s -> Maybe (Scope s) -> Eval s (Scope s)
newScope env parent = st $ do
  i <- readSTRef (eCounter env)
  writeSTRef (eCounter env) (i + 1)
  Scope i <$> newSTRef Map.empty <*> pure parent

setVar :: Scope s -> Text -> Value -> Eval s ()
setVar sc k v = st (modifySTRef' (scVars sc) (Map.insert k v))

lookupVar :: Scope s -> Text -> Eval s Value
lookupVar sc k = st (go (Just sc))
  where
    go Nothing = pure (if k == "range" then VRange else VUndefined)
    go (Just s) = do
      m <- readSTRef (scVars s)
      case Map.lookup k m of
        Just v -> pure v
        Nothing -> go (scParent s)

emit :: Env s -> Text -> Eval s ()
emit env t = st (modifySTRef' (eOut env) (t :))

-- | Run an action with a fresh output buffer and return what it produced.
capture :: Env s -> (Env s -> Eval s ()) -> Eval s Text
capture env act = do
  ref <- st (newSTRef [])
  act env {eOut = ref}
  T.concat . reverse <$> st (readSTRef ref)

loadTemplate :: Env s -> Text -> Eval s Template
loadTemplate env name = case eTemplates env of
  Templates m -> case ML.lookup name m of
    Nothing -> throw TemplateNotFound
    Just (Left k) -> throw k
    Just (Right t) -> pure t

-- | Render a template with the given root variables.
renderTemplate :: Templates -> Text -> [(Text, Value)] -> Either ErrorKind Text
renderTemplate tpls name vars = runST (runExceptT go)
  where
    go = do
      registry <- st (newSTRef IM.empty)
      counter <- st (newSTRef 0)
      out <- st (newSTRef [])
      let env = Env tpls registry counter out Nothing
      tpl <- loadTemplate env name
      root <- newScope env Nothing
      forM_ vars (uncurry (setVar root))
      renderInto env root tpl
      T.concat . reverse <$> st (readSTRef out)

-- | Render a template (the main one or an included one) into the current
-- output, in a new template scope below @parent@.
renderInto :: Env s -> Scope s -> Template -> Eval s ()
renderInto env parent tpl = do
  ts <- newScope env (Just parent)
  chains <- st (newSTRef (Map.map (: []) (tplBlocks tpl)))
  let env' = env {eRender = Just (Render ts chains)}
      runBody t = do
        mp <- execTop env' ts chains (tplBody t)
        case mp of
          Nothing -> pure ()
          Just p -> runBody p
  runBody tpl

-- | Execute a template body at top level. Returns the parent template if an
-- @extends@ tag ran.
execTop :: Env s -> Scope s -> STRef s (Map.Map Text [[Node]]) -> [Node] -> Eval s (Maybe Template)
execTop env ts chains = go
  where
    go [] = pure Nothing
    go (NExtends e : rest) = do
      v <- eval env ts e
      name <- templateName v
      parent <- loadTemplate env name
      st (modifySTRef' chains (\m -> foldl add m (Map.toList (tplBlocks parent))))
      forM_ rest $ \n -> case n of
        NSet {} -> exec env ts n
        NMacro {} -> exec env ts n
        _ -> pure ()
      pure (Just parent)
    go (n : rest) = exec env ts n >> go rest
    add m (k, body) = Map.insertWith (\_ old -> old ++ [body]) k [body] m

templateName :: Value -> Eval s Text
templateName v = case v of
  VString s -> pure s
  VUndefined -> throw UndefinedError
  _ -> throw TypeError

exec :: Env s -> Scope s -> Node -> Eval s ()
exec env sc node = case node of
  NText t -> emit env t
  NPrint e -> do
    v <- eval env sc e
    t <- liftR (toText v)
    emit env t
  NIf branches els -> do
    let pick [] = mapM_ (exec env sc) els
        pick ((c, body) : more) = do
          v <- eval env sc c
          b <- liftR (truthy v)
          if b then mapM_ (exec env sc) body else pick more
    pick branches
  NFor var e body els -> do
    v <- eval env sc e
    xs <- liftR (sequenceView v)
    case xs of
      [] -> mapM_ (exec env sc) els
      _ -> do
        let len = length xs
            n = toInteger len
        forM_ (zip [0 ..] xs) $ \(i, x) -> do
          inner <- newScope env (Just sc)
          setVar inner var x
          setVar inner "loop" $
            mkDict
              [ ("index", VInt (i + 1))
              , ("index0", VInt i)
              , ("first", VBool (i == 0))
              , ("last", VBool (i + 1 == n))
              , ("length", VInt n)
              ]
          mapM_ (exec env inner) body
  NSet var e -> eval env sc e >>= setVar sc var
  NMacro name params body -> do
    st (modifySTRef' (eRegistry env) (IM.insert (scId sc) sc))
    setVar sc name (VMacro (Macro name params body (scId sc)))
  NInclude e -> do
    v <- eval env sc e
    name <- templateName v
    tpl <- loadTemplate env name
    renderInto env sc tpl
  NExtends _ -> pure ()
  NBlock name body -> case eRender env of
    Nothing -> pure ()
    Just r -> do
      chains <- st (readSTRef (rChains r))
      case Map.lookup name chains of
        Just (b : _) -> renderBlock env r name 0 b
        _ -> renderBlock env r name 0 body

renderBlock :: Env s -> Render s -> Text -> Int -> [Node] -> Eval s ()
renderBlock env r name k body = do
  bs <- newScope env (Just (rScope r))
  setVar bs "super" (VSuper name k)
  mapM_ (exec env bs) body

-- ---------------------------------------------------------------------------
-- Expressions

eval :: Env s -> Scope s -> Expr -> Eval s Value
eval env sc expr = case expr of
  EInt i -> pure (VInt i)
  EFloat d -> pure (VFloat d)
  EString s -> pure (VString s)
  EBool b -> pure (VBool b)
  ENone -> pure VNone
  EName n -> lookupVar sc n
  EList xs -> mkList <$> mapM go xs
  ENeg e -> go e >>= liftR . negateValue
  ENot e -> do
    v <- go e
    VBool . not <$> liftR (truthy v)
  EBin op a b -> do
    x <- go a
    y <- go b
    liftR (binaryOp op x y)
  EAnd a b -> do
    x <- go a
    t <- liftR (truthy x)
    if t then go b else pure x
  EOr a b -> do
    x <- go a
    t <- liftR (truthy x)
    if t then pure x else go b
  ECompare a rest -> do
    x <- go a
    let chain _ [] = pure (VBool True)
        chain l ((op, e) : more) = do
          r <- go e
          ok <- liftR (compareOp op l r)
          if ok then chain r more else pure (VBool False)
    chain x rest
  EFilter e name args -> do
    x <- go e
    as <- mapM go args
    liftR (applyFilter name x as)
  EIsDefined neg e -> do
    v <- go e
    pure (VBool (isDefined v /= neg))
  EAttr e name -> do
    v <- go e
    liftR (getItem v (VString name))
  EIndex e k -> do
    v <- go e
    i <- go k
    liftR (getItem v i)
  ECall f args kws -> do
    fv <- go f
    as <- mapM go args
    ks <- forM kws $ \(k, e) -> (,) k <$> go e
    callValue env sc fv as ks
  where
    go = eval env sc

callValue :: Env s -> Scope s -> Value -> [Value] -> [(Text, Value)] -> Eval s Value
callValue env sc f args kws = case f of
  VMacro m -> callMacro env m args kws
  VRange -> liftR (callRange args kws)
  VSuper name k -> do
    when (not (null args) || not (null kws)) $ throw TypeError
    case eRender env of
      Nothing -> throw UndefinedError
      Just r -> do
        chains <- st (readSTRef (rChains r))
        case Map.lookup name chains of
          Just bodies | k + 1 < length bodies ->
            VString <$> capture env (\e -> renderBlock e r name (k + 1) (bodies !! (k + 1)))
          _ -> throw UndefinedError
  VUndefined -> throw UndefinedError
  _ -> const (throw TypeError) sc

callRange :: [Value] -> [(Text, Value)] -> Either ErrorKind Value
callRange args kws
  | not (null kws) = Left TypeError
  | length args < 1 || length args > 3 = Left TypeError
  | otherwise = do
      ints <- mapM toI args
      let (start, stop, step) = case ints of
            [s] -> (0, s, 1)
            [a, b] -> (a, b, 1)
            [a, b, c] -> (a, b, c)
            _ -> (0, 0, 1)
      when (step == 0) $ Left TypeError
      Right (VList (Seq.fromList (map VInt (takeWhile (if step > 0 then (< stop) else (> stop)) (iterate (+ step) start)))))
  where
    toI v = case v of
      VUndefined -> Left UndefinedError
      _ -> maybe (Left TypeError) Right (toInteger' v)

callMacro :: Env s -> Macro -> [Value] -> [(Text, Value)] -> Eval s Value
callMacro env m args kws = do
  defScope <- st (IM.lookup (macroScope m) <$> readSTRef (eRegistry env))
  ms <- newScope env defScope
  let params = macroParams m
      names = map fst params
  when (length args > length params) $ throw TypeError
  zipWithM_ (\(n, _) v -> setVar ms n v) params args
  let boundPositional = take (length args) names
  forM_ kws $ \(k, v) -> do
    when (k `notElem` names || k `elem` boundPositional) $ throw TypeError
    setVar ms k v
  let boundKw = map fst kws
  forM_ (drop (length args) params) $ \(n, def) ->
    when (n `notElem` boundKw) $ case def of
      Just e -> eval env ms e >>= setVar ms n
      Nothing -> setVar ms n VUndefined
  VString <$> capture env (\e -> mapM_ (exec e ms) (macroBody m))

