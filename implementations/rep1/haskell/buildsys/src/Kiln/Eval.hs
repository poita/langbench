-- | The KBL interpreter: scopes, expressions, statements, rules, includes and
-- step construction.  Evaluating a build file yields the build's 'Decls'.
module Kiln.Eval
  ( Decls (..)
  , evaluateBuild
  , evalExprText
  ) where

import Control.Exception (throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Foldable (toList)
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import Kiln.Builtins
import Kiln.Command
import Kiln.Error
import Kiln.Lexer (tokenizeLine)
import Kiln.Parser
import Kiln.Path
import Kiln.Step
import Kiln.Syntax
import Kiln.Value
import Kiln.Workspace (Workspace, lookupContent)

-- | Everything a build's evaluation declared.
data Decls = Decls
  { declSteps :: [Step]
    -- ^ in serial order
  , declPhonies :: [Phony]
    -- ^ in declaration order
  , declDefaults :: [BS.ByteString]
  }

data Scope = Scope
  { scVars :: IORef (Map BS.ByteString Value)
  , scParent :: Maybe Scope
  }

data Rule = Rule
  { ruleParams :: [Param]
  , ruleBody :: [Stmt]
  , ruleScope :: Scope
  }

data EvalState = EvalState
  { esSteps :: [Step]
  , esNextSerial :: !Int
  , esPhonies :: [Phony]
  , esPhonyNames :: Set.Set BS.ByteString
  , esRules :: Map BS.ByteString Rule
  , esDefaults :: [BS.ByteString]
  }

data Env = Env
  { envWs :: Workspace
  , envState :: IORef EvalState
  }

data Ctx = Ctx
  { ctxScope :: Scope
  , ctxDepth :: !Int
  , ctxStack :: [BS.ByteString]
  }

newScope :: Maybe Scope -> IO Scope
newScope p = (`Scope` p) <$> newIORef Map.empty

lookupVar :: Scope -> BS.ByteString -> IO (Maybe Value)
lookupVar sc n = do
  m <- readIORef (scVars sc)
  case Map.lookup n m of
    Just v -> pure (Just v)
    Nothing -> maybe (pure Nothing) (`lookupVar` n) (scParent sc)

throw :: KilnError -> IO a
throw = throwIO

-- | Evaluate the root build file @main.kiln@ (which must exist in the workspace).
evaluateBuild :: Workspace -> IO (Either KilnError Decls)
evaluateBuild ws = do
  ref <- newIORef (EvalState [] 0 [] Set.empty Map.empty [])
  root <- newScope Nothing
  let env = Env ws ref
  r <- try $ do
    src <- maybe (throw ENoBuildFile) pure (lookupContent buildFilePath ws)
    stmts <- either (throw . EParse buildFilePath) pure (parseSource src)
    mapM_ (execStmt env (Ctx root 0 [buildFilePath])) stmts
  case r of
    Left e -> pure (Left e)
    Right () -> do
      st <- readIORef ref
      pure (Right (Decls (reverse (esSteps st)) (reverse (esPhonies st)) (reverse (esDefaults st))))

-- | Evaluate a single expression given as source text, in an empty scope
-- (useful for experimenting with the expression language).
evalExprText :: Workspace -> BS.ByteString -> IO (Either KilnError Value)
evalExprText ws src = case tokenizeLine src >>= parseExprTokens of
  Nothing -> pure (Left (EParse "<expr>" 1))
  Just e -> do
    ref <- newIORef (EvalState [] 0 [] Set.empty Map.empty [])
    sc <- newScope Nothing
    try (evalExpr (Env ws ref) sc e)

-- ---------------------------------------------------------------------------
-- Expressions

typeErr :: BS.ByteString -> BS.ByteString -> Value -> IO a
typeErr site expected v = throw (EType site expected (typeName v))

evalExpr :: Env -> Scope -> Expr -> IO Value
evalExpr env sc = go
  where
    go e = case e of
      EInt n -> pure (VInt n)
      EBool b -> pure (VBool b)
      EStr s -> pure (VStr s)
      EInterp parts -> do
        chunks <- forM parts $ \p -> case p of
          PLit s -> pure s
          PHole x -> do
            v <- go x
            maybe (throw EInterpList) pure (valueText v)
        pure (VStr (BS.concat chunks))
      EVar n -> lookupVar sc n >>= maybe (throw (EUnknownVar n)) pure
      EList es -> VList . Seq.fromList <$> mapM go es
      EUnary op x -> do
        v <- go x
        case (op, v) of
          (Not, VBool b) -> pure (VBool (not b))
          (Not, _) -> typeErr "operator !" "bool" v
          (Neg, VInt n) -> pure (VInt (negate n))
          (Neg, _) -> typeErr "operator -" "int" v
      EBinary op l r -> binary op l r
      ECall name args -> call name args
      EIndex x i -> do
        xv <- go x
        iv <- go i
        n <- case iv of
          VInt k -> pure k
          _ -> typeErr "index" "int" iv
        let pick len fetch =
              let k = fromIntegral n :: Int
                  idx = if n < 0 then len + k else k
               in if n < negate (fromIntegral len) || n >= fromIntegral len
                    then throw (EArg "fn" "index" "out of range")
                    else pure (fetch idx)
        case xv of
          VStr s -> pick (BS.length s) (\k -> VStr (BS.take 1 (BS.drop k s)))
          VList l -> pick (Seq.length l) (Seq.index l)
          _ -> typeErr "index target" "str|list" xv

    binary op l r = case op of
      Or -> shortCircuit True l r
      And -> shortCircuit False l r
      _ -> do
        lv <- go l
        rv <- go r
        apply op lv rv

    shortCircuit stopOn l r = do
      let site = binOpText (if stopOn then Or else And)
      lv <- go l
      case lv of
        VBool b
          | b == stopOn -> pure lv
          | otherwise -> do
              rv <- go r
              case rv of
                VBool _ -> pure rv
                _ -> typeErr ("operator " <> site) "bool" rv
        _ -> typeErr ("operator " <> site) "bool" lv

    apply op lv rv = case op of
      Eq -> pure (VBool (lv == rv))
      Ne -> pure (VBool (lv /= rv))
      Lt -> pure (VBool (lv < rv))
      Le -> pure (VBool (lv <= rv))
      Gt -> pure (VBool (lv > rv))
      Ge -> pure (VBool (lv >= rv))
      ConcatList -> case (lv, rv) of
        (VList a, VList b) -> pure (VList (a Seq.>< b))
        (VList _, _) -> typeErr site "list" rv
        _ -> typeErr site "list" lv
      ConcatStr -> case (lv, rv) of
        (VStr a, VStr b) -> pure (VStr (a <> b))
        (VStr _, _) -> typeErr site "str" rv
        _ -> typeErr site "str" lv
      _ -> case (lv, rv) of
        (VInt a, VInt b) -> arith op a b
        (VInt _, _) -> typeErr site "int" rv
        _ -> typeErr site "int" lv
      where
        site = "operator " <> binOpText op

    arith :: BinOp -> Int64 -> Int64 -> IO Value
    arith op a b = case op of
      Add -> pure (VInt (a + b))
      Sub -> pure (VInt (a - b))
      Mul -> pure (VInt (a * b))
      Div
        | b == 0 -> throw EDivZero
        | b == -1 -> pure (VInt (negate a))
        | otherwise -> pure (VInt (a `quot` b))
      Mod
        | b == 0 -> throw EDivZero
        | b == -1 -> pure (VInt 0)
        | otherwise -> pure (VInt (a `rem` b))
      _ -> throw (EInternal "arith")

    call name args = case lookupBuiltin name of
      Nothing -> throw (EUnknownFunc name)
      Just b -> do
        vals <- mapM go args
        let n = length vals
        when (n < bMinArgs b || n > bMaxArgs b) $
          throw $
            EArity "fn" name (if bMinArgs b == bMaxArgs b then showBS (bMinArgs b) else showBS (bMinArgs b) <> "-" <> showBS (bMaxArgs b)) n
        forM_ (zip [0 ..] vals) $ \(i, v) -> do
          let ty = paramType b i
          unless (tyAccepts ty v) $
            throw (EType ("fn " <> name <> " argument " <> showBS (i + 1)) (tyName ty) (typeName v))
        either throw pure (bRun b (envWs env) vals)

showBS :: Int -> BS.ByteString
showBS = BC.pack . show

-- | A @str@ or list-of-@str@ value (the @strlist@ type).
strList :: BS.ByteString -> Value -> IO [BS.ByteString]
strList site v = case v of
  VStr s -> pure [s]
  VList l -> forM (toList l) $ \x -> case x of
    VStr s -> pure s
    _ -> typeErr site "strlist" x
  _ -> typeErr site "strlist" v

-- ---------------------------------------------------------------------------
-- Statements

execStmt :: Env -> Ctx -> Stmt -> IO ()
execStmt env ctx stmt = case stmt of
  SLet name e -> do
    v <- eval e
    m <- readIORef (scVars sc)
    when (Map.member name m) $ throw (ERedefine name)
    writeIORef (scVars sc) (Map.insert name v m)
  SSet name e -> do
    v <- eval e
    ok <- assign sc name v
    unless ok $ throw (ESetUndefined name)
  SInclude e -> do
    v <- eval e
    path <- case v of
      VStr s -> pure s
      _ -> typeErr "include path" "str" v
    unless (isWorkspacePath path) $ throw (EBadPath path)
    content <- maybe (throw (EIncludeMissing path)) pure (lookupContent path (envWs env))
    when (path `elem` ctxStack ctx) $ throw (EIncludeCycle path)
    stmts <- either (throw . EParse path) pure (parseSource content)
    mapM_ (execStmt env ctx {ctxStack = path : ctxStack ctx}) stmts
  SAbort e -> do
    v <- eval e
    case v of
      VStr s -> throw (EAbort s)
      _ -> typeErr "abort message" "str" v
  SDefault e -> do
    v <- eval e
    names <- strList "default" v
    modifyIORef' (envState env) $ \st -> st {esDefaults = reverse names ++ esDefaults st}
  SPhony name e -> do
    v <- eval e
    deps <- strList ("phony " <> name) v
    mapM_ (either throw pure . validateReference) deps
    st <- readIORef (envState env)
    when (Set.member name (esPhonyNames st)) $ throw (EDupPhony name)
    writeIORef (envState env) st {esPhonies = Phony name deps : esPhonies st, esPhonyNames = Set.insert name (esPhonyNames st)}
  SUse name args -> execUse env ctx name args
  SWhen branches otherwise_ -> goWhen branches otherwise_
  SEach mi name e body -> do
    v <- eval e
    items <- case v of
      VList l -> pure (toList l)
      _ -> typeErr "each subject" "list" v
    forM_ (zip [0 :: Int64 ..] items) $ \(i, x) -> do
      child <- newScope (Just sc)
      writeIORef (scVars child) $
        Map.fromList ([(n, VInt i) | Just n <- [mi]] ++ [(name, x)])
      mapM_ (execStmt env ctx {ctxScope = child}) body
  SRule name params body -> do
    st <- readIORef (envState env)
    when (Map.member name (esRules st)) $ throw (ERedefine name)
    writeIORef (envState env) st {esRules = Map.insert name (Rule params body sc) (esRules st)}
  SStep fields -> execStep env ctx fields
  where
    sc = ctxScope ctx
    eval = evalExpr env sc
    goWhen [] otherwise_ = case otherwise_ of
      Nothing -> pure ()
      Just body -> runBranch body
    goWhen ((c, body) : rest) otherwise_ = do
      v <- eval c
      case v of
        VBool True -> runBranch body
        VBool False -> goWhen rest otherwise_
        _ -> typeErr "when condition" "bool" v
    runBranch body = do
      child <- newScope (Just sc)
      mapM_ (execStmt env ctx {ctxScope = child}) body

-- | Rebind an existing variable in the innermost scope that has it.
assign :: Scope -> BS.ByteString -> Value -> IO Bool
assign sc name v = do
  m <- readIORef (scVars sc)
  if Map.member name m
    then writeIORef (scVars sc) (Map.insert name v m) >> pure True
    else maybe (pure False) (\p -> assign p name v) (scParent sc)

execUse :: Env -> Ctx -> BS.ByteString -> [Arg] -> IO ()
execUse env ctx name args = do
  st <- readIORef (envState env)
  rule <- maybe (throw (EUnknownRule name)) pure (Map.lookup name (esRules st))
  let depth = ctxDepth ctx + 1
  when (depth > 64) $ throw (ERuleRecursion name)
  evaled <- forM args $ \a -> case a of
    Pos e -> Left <$> evalExpr env (ctxScope ctx) e
    Kw k e -> (\v -> Right (k, v)) <$> evalExpr env (ctxScope ctx) e
  let positional = [v | Left v <- evaled]
      keywords = [kv | Right kv <- evaled]
      params = ruleParams rule
      pnames = [n | Param n _ <- params]
  scope <- newScope (Just (ruleScope rule))
  when (length positional > length params) $
    throw (EArity "rule" name (showBS (length params)) (length positional))
  writeIORef (scVars scope) (Map.fromList (zip pnames positional))
  forM_ keywords $ \(k, v) -> do
    unless (k `elem` pnames) $ throw (EArg "rule" name ("unknown argument " <> k))
    m <- readIORef (scVars scope)
    when (Map.member k m) $ throw (EArg "rule" name ("duplicate argument " <> k))
    writeIORef (scVars scope) (Map.insert k v m)
  forM_ params $ \(Param p def) -> do
    m <- readIORef (scVars scope)
    unless (Map.member p m) $ case def of
      Nothing -> throw (EArg "rule" name ("missing argument " <> p))
      Just d -> do
        v <- evalExpr env scope d
        modifyIORef' (scVars scope) (Map.insert p v)
  mapM_ (execStmt env ctx {ctxScope = scope, ctxDepth = depth}) (ruleBody rule)

-- ---------------------------------------------------------------------------
-- Steps

execStep :: Env -> Ctx -> [StepField] -> IO ()
execStep env ctx fields = do
  draft <- foldM field emptyDraft fields
  st <- readIORef (envState env)
  step <- either throw pure (validateStep (esNextSerial st) draft)
  writeIORef (envState env) st {esSteps = step : esSteps st, esNextSerial = esNextSerial st + 1}
  where
    eval = evalExpr env (ctxScope ctx)
    field d f = case f of
      FOut e -> (\xs -> d {draftOuts = draftOuts d ++ xs}) <$> (eval e >>= strList "field out")
      FIn e -> (\xs -> d {draftIns = draftIns d ++ xs}) <$> (eval e >>= strList "field in")
      FAfter e -> (\xs -> d {draftAfter = draftAfter d ++ xs}) <$> (eval e >>= strList "field after")
      FCost e -> do
        when (isJust (draftCost d)) $ throw (EStepField "duplicate cost")
        v <- eval e
        case v of
          VInt n
            | n < 0 -> throw (EArg "field" "cost" "negative")
            | otherwise -> pure d {draftCost = Just (fromIntegral n)}
          _ -> typeErr "field cost" "int" v
      FDepfile e -> do
        when (isJust (draftDepfile d)) $ throw (EStepField "duplicate depfile")
        v <- eval e
        case v of
          VStr s -> pure d {draftDepfile = Just s}
          _ -> typeErr "field depfile" "str" v
      FCmd name args -> do
        when (isJust (draftCmd d)) $ throw (EStepField "duplicate cmd")
        kind <- maybe (throw (EUnknownCmd name)) pure (lookupCommand name)
        vals <- mapM eval args
        let params = cmdParams kind
        when (length vals /= length params) $
          throw (EArity "cmd" name (showBS (length params)) (length vals))
        cargs <- forM (zip3 [1 :: Int ..] params vals) $ \(i, ty, v) -> case (ty, v) of
          (TyStr, VStr s) -> pure (CStr s)
          (TyInt, VInt n) -> pure (CInt n)
          _ -> typeErr ("cmd " <> name <> " argument " <> showBS i) (if ty == TyStr then "str" else "int") v
        pure d {draftCmd = Just (Command kind cargs)}
