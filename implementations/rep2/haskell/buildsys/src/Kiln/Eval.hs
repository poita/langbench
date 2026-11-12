-- | The KBL interpreter: evaluates a build file (and its includes) into a
-- 'Program' of steps, phony targets and default targets.
module Kiln.Eval
  ( Program (..)
  , evalProgram
  ) where

import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State.Strict
import qualified Data.ByteString as B
import Data.Foldable (toList)
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import qualified Data.Sequence as Seq

import Kiln.Builtins
import Kiln.Command
import Kiln.Error
import Kiln.Parser
import Kiln.Step
import Kiln.Syntax
import Kiln.Text (renderInt)
import Kiln.Value
import Kiln.Workspace

-- | The result of evaluating the build files.
data Program = Program
  { progSteps :: [Step]
    -- ^ in serial order
  , progPhonies :: [(B.ByteString, [B.ByteString])]
    -- ^ name (without @\@@) and dependencies, in declaration order
  , progDefaults :: [B.ByteString]
  }

data Scope = Scope
  { scopeParent :: !(Maybe Int)
  , scopeVars :: !(M.Map B.ByteString Value)
  }

data Rule = Rule [Param] [Stmt] !Int

data St = St
  { stScopes :: !(IM.IntMap Scope)
  , stNextScope :: !Int
  , stSteps :: [Step]
  , stStepCount :: !Int
  , stPhonies :: !(M.Map B.ByteString [B.ByteString])
  , stPhonyOrder :: [B.ByteString]
  , stRules :: !(M.Map B.ByteString Rule)
  , stDefaults :: [B.ByteString]
  }

type Eval = ReaderT Workspace (StateT St (Either BuildError))

-- | Where a statement runs: its scope, the rule instantiation depth and the
-- include stack.
data Ctx = Ctx
  { cScope :: !Int
  , cDepth :: !Int
  , cIncludes :: [B.ByteString]
  }

buildFilePath :: B.ByteString
buildFilePath = "main.kiln"

-- | Evaluate @main.kiln@ against a workspace. Errors are raised in execution
-- order, so the first error encountered is the one returned.
evalProgram :: Workspace -> Either BuildError Program
evalProgram ws = case lookupFile buildFilePath ws of
  Nothing -> Left ENoBuildFile
  Just f -> do
    stmts <- parseBuildFile buildFilePath (fileContent f)
    let st0 = St (IM.singleton 0 (Scope Nothing M.empty)) 1 [] 0 M.empty [] M.empty []
    st <- execStateT (runReaderT (execStmts (Ctx 0 0 [buildFilePath]) stmts) ws) st0
    pure
      Program
        { progSteps = reverse (stSteps st)
        , progPhonies = [(n, stPhonies st M.! n) | n <- reverse (stPhonyOrder st)]
        , progDefaults = reverse (stDefaults st)
        }

------------------------------------------------------------------------
-- Scopes

newScope :: Maybe Int -> Eval Int
newScope parent = do
  st <- get
  let i = stNextScope st
  put st {stScopes = IM.insert i (Scope parent M.empty) (stScopes st), stNextScope = i + 1}
  pure i

getScope :: Int -> Eval Scope
getScope i = gets ((IM.! i) . stScopes)

lookupVar :: Int -> B.ByteString -> Eval (Maybe Value)
lookupVar i n = do
  sc <- getScope i
  case M.lookup n (scopeVars sc) of
    Just v -> pure (Just v)
    Nothing -> maybe (pure Nothing) (`lookupVar` n) (scopeParent sc)

bindVar :: Int -> B.ByteString -> Value -> Eval ()
bindVar i n v = modify' $ \st ->
  st {stScopes = IM.adjust (\sc -> sc {scopeVars = M.insert n v (scopeVars sc)}) i (stScopes st)}

-- | Rebind in the innermost scope that binds the name.
setVar :: Int -> B.ByteString -> Value -> Eval Bool
setVar i n v = do
  sc <- getScope i
  if M.member n (scopeVars sc)
    then bindVar i n v >> pure True
    else maybe (pure False) (\p -> setVar p n v) (scopeParent sc)

------------------------------------------------------------------------
-- Expressions

typeErr :: B.ByteString -> B.ByteString -> Value -> Eval a
typeErr site expected v = throwError (EType site expected (typeName v))

evalExpr :: Int -> Expr -> Eval Value
evalExpr sc = go
  where
    go e = case e of
      EIntLit n -> pure (VInt n)
      EBoolLit b -> pure (VBool b)
      EStrLit s -> pure (VStr s)
      EInterpLit parts -> VStr . B.concat <$> mapM part parts
      EVar n -> lookupVar sc n >>= maybe (throwError (EUnknownVar n)) pure
      EListLit es -> VList . Seq.fromList <$> mapM go es
      EUnary op x -> do
        v <- go x
        case (op, v) of
          (Not, VBool b) -> pure (VBool (not b))
          (Neg, VInt n) -> pure (VInt (negate n))
          (Not, _) -> typeErr "operator !" "bool" v
          (Neg, _) -> typeErr "operator -" "int" v
      EBinary op l r -> binary op l r
      ECall name args -> do
        b <- maybe (throwError (EUnknownFunc name)) pure (lookupBuiltin name)
        vs <- mapM go args
        ws <- ask
        either throwError pure (applyBuiltin ws name b vs)
      EIndex x i -> do
        xv <- go x
        iv <- go i
        n <- case iv of
          VInt n -> pure n
          _ -> typeErr "index" "int" iv
        case xv of
          VStr s -> VStr . B.singleton <$> at (B.length s) n (B.index s)
          VList l -> at (Seq.length l) n (Seq.index l)
          _ -> typeErr "index target" "str|list" xv
    at len n f
      | n >= -len && n < len = pure (f (if n < 0 then len + n else n))
      | otherwise = throwError (EArg "fn" "index" "out of range")
    part (PLit s) = pure s
    part (PExpr x) = do
      v <- go x
      maybe (throwError EInterp) pure (renderScalar v)
    binary op l r = case op of
      Or -> shortCircuit True
      And -> shortCircuit False
      _ -> do
        lv <- go l
        rv <- go r
        let need ty ok v = if ok v then pure () else typeErr spell ty v
        case op of
          Eq -> pure (VBool (lv == rv))
          Ne -> pure (VBool (lv /= rv))
          Lt -> pure (VBool (lv < rv))
          Le -> pure (VBool (lv <= rv))
          Gt -> pure (VBool (lv > rv))
          Ge -> pure (VBool (lv >= rv))
          ListCat -> do
            need "list" isList lv >> need "list" isList rv
            case (lv, rv) of
              (VList a, VList b) -> pure (VList (a Seq.>< b))
              _ -> impossible
          StrCat -> do
            need "str" isStr lv >> need "str" isStr rv
            case (lv, rv) of
              (VStr a, VStr b) -> pure (VStr (B.append a b))
              _ -> impossible
          _ -> do
            need "int" isInt lv >> need "int" isInt rv
            case (lv, rv) of
              (VInt a, VInt b) -> arith op a b
              _ -> impossible
      where
        spell = "operator " <> binOpSpelling op
        shortCircuit stopOn = do
          lv <- go l
          a <- case lv of
            VBool b -> pure b
            _ -> typeErr spell "bool" lv
          if a == stopOn
            then pure (VBool stopOn)
            else do
              rv <- go r
              case rv of
                VBool b -> pure (VBool b)
                _ -> typeErr spell "bool" rv
    arith op a b = case op of
      Add -> pure (VInt (a + b))
      Sub -> pure (VInt (a - b))
      Mul -> pure (VInt (a * b))
      Div -> if b == 0 then throwError EDivZero else pure (VInt (a `quot` b))
      Mod -> if b == 0 then throwError EDivZero else pure (VInt (a `rem` b))
      _ -> impossible
    impossible = error "eval: operand types were checked"
    isList = \case VList _ -> True; _ -> False
    isStr = \case VStr _ -> True; _ -> False
    isInt = \case VInt _ -> True; _ -> False

-- | A @str@ or a list of @str@ (the @strlist@ type).
strList :: B.ByteString -> Value -> Eval [B.ByteString]
strList site v = case v of
  VStr s -> pure [s]
  VList l -> forM (toList l) $ \case
    VStr s -> pure s
    x -> typeErr site "strlist" x
  _ -> typeErr site "strlist" v

------------------------------------------------------------------------
-- Statements

execStmts :: Ctx -> [Stmt] -> Eval ()
execStmts ctx = mapM_ (execStmt ctx)

execStmt :: Ctx -> Stmt -> Eval ()
execStmt ctx stmt = case stmt of
  SLet n e -> do
    v <- eval e
    sc <- getScope sc0
    when (M.member n (scopeVars sc)) (throwError (ERedefine n))
    bindVar sc0 n v
  SSet n e -> do
    v <- eval e
    found <- setVar sc0 n v
    unless found (throwError (ESetUndefined n))
  SInclude e -> do
    v <- eval e
    path <- case v of
      VStr s -> pure s
      _ -> typeErr "include path" "str" v
    unless (isWorkspacePath path) (throwError (EBadPath path))
    ws <- ask
    f <- maybe (throwError (EIncludeMissing path)) pure (lookupFile path ws)
    when (path `elem` cIncludes ctx) (throwError (EIncludeCycle path))
    stmts <- either throwError pure (parseBuildFile path (fileContent f))
    execStmts ctx {cIncludes = path : cIncludes ctx} stmts
  SAbort e -> do
    v <- eval e
    case v of
      VStr s -> throwError (EAbort s)
      _ -> typeErr "abort message" "str" v
  SDefault e -> do
    ts <- eval e >>= strList "default"
    modify' $ \st -> st {stDefaults = reverse ts ++ stDefaults st}
  SPhony n e -> do
    deps <- eval e >>= strList ("phony " <> n)
    forM_ deps $ \d -> unless (isPhonyShape d || isWorkspacePath d) (throwError (EBadPath d))
    dup <- gets (M.member n . stPhonies)
    when dup (throwError (EDupPhony n))
    modify' $ \st ->
      st {stPhonies = M.insert n deps (stPhonies st), stPhonyOrder = n : stPhonyOrder st}
  SUse name args -> execUse ctx name args
  SWhen branches otherwise_ -> go branches
    where
      go [] = forM_ otherwise_ (runBody ctx)
      go ((c, body) : rest) = do
        v <- eval c
        case v of
          VBool True -> runBody ctx body
          VBool False -> go rest
          _ -> typeErr "when condition" "bool" v
  SEach mi n subj body -> do
    v <- eval subj
    items <- case v of
      VList l -> pure (toList l)
      _ -> typeErr "each subject" "list" v
    forM_ (zip [0 :: Int ..] items) $ \(i, x) -> do
      s <- newScope (Just sc0)
      forM_ mi $ \iv -> bindVar s iv (VInt i)
      bindVar s n x
      execStmts ctx {cScope = s} body
  SRule n params body -> do
    exists <- gets (M.member n . stRules)
    when exists (throwError (ERedefine n))
    modify' $ \st -> st {stRules = M.insert n (Rule params body sc0) (stRules st)}
  SStep fields -> execStep ctx fields
  where
    sc0 = cScope ctx
    eval = evalExpr sc0
    runBody c body = do
      s <- newScope (Just (cScope c))
      execStmts c {cScope = s} body

execUse :: Ctx -> B.ByteString -> [Arg] -> Eval ()
execUse ctx name args = do
  rules <- gets stRules
  Rule params body defScope <- maybe (throwError (EUnknownRule name)) pure (M.lookup name rules)
  when (cDepth ctx + 1 > 64) (throwError (ERuleRecursion name))
  vals <- forM args $ \case
    Positional e -> (,) Nothing <$> evalExpr (cScope ctx) e
    Keyword k e -> (,) (Just k) <$> evalExpr (cScope ctx) e
  scope <- newScope (Just defScope)
  let positional = [v | (Nothing, v) <- vals]
      names = [n | Param n _ <- params]
  when (length positional > length params) $
    throwError (EArity "rule" name (renderInt (length params)) (length positional))
  forM_ (zip names positional) $ \(n, v) -> bindVar scope n v
  forM_ [(k, v) | (Just k, v) <- vals] $ \(k, v) -> do
    unless (k `elem` names) (throwError (EArg "rule" name ("unknown argument " <> k)))
    sc <- getScope scope
    when (M.member k (scopeVars sc)) (throwError (EArg "rule" name ("duplicate argument " <> k)))
    bindVar scope k v
  forM_ params $ \(Param n def) -> do
    sc <- getScope scope
    unless (M.member n (scopeVars sc)) $ case def of
      Nothing -> throwError (EArg "rule" name ("missing argument " <> n))
      Just d -> evalExpr scope d >>= bindVar scope n
  execStmts ctx {cScope = scope, cDepth = cDepth ctx + 1} body

------------------------------------------------------------------------
-- Steps

data Acc = Acc
  { aOuts :: [[B.ByteString]]
  , aIns :: [[B.ByteString]]
  , aAfter :: [[B.ByteString]]
  , aCost :: Maybe Int
  , aDepfile :: Maybe B.ByteString
  , aCmd :: Maybe Command
  }

execStep :: Ctx -> [StepField] -> Eval ()
execStep ctx fields = do
  acc <- foldM field (Acc [] [] [] Nothing Nothing Nothing) fields
  cmd <- maybe (throwError (EStepField "missing cmd")) pure (aCmd acc)
  let outs = concat (reverse (aOuts acc))
      ins = concat (reverse (aIns acc))
      after = concat (reverse (aAfter acc))
  when (null outs) (throwError (EStepField "missing out"))
  forM_ (outs ++ maybe [] pure (aDepfile acc)) $ \p -> do
    unless (isWorkspacePath p) (throwError (EBadPath p))
    unless (isGenerated p) (throwError (EOutputPath p))
  forM_ (ins ++ after) $ \r ->
    unless (isPhonyShape r || isWorkspacePath r) (throwError (EBadPath r))
  let fileIns = length (filter (not . isPhonyRef) ins)
  forM_ (shapeError (cmdName cmd) fileIns (length outs) (aDepfile acc /= Nothing)) throwError
  forM_ (argError cmd) throwError
  st <- get
  let serial = stStepCount st
      step =
        Step
          { stepSerial = serial
          , stepDeclaredOuts = outs
          , stepDepfile = aDepfile acc
          , stepIns = ins
          , stepAfter = after
          , stepCommand = cmd
          , stepCost = maybe (csCost (cmdSpec (cmdName cmd))) id (aCost acc)
          }
  put st {stSteps = step : stSteps st, stStepCount = serial + 1}
  where
    sc = cScope ctx
    field acc f = case f of
      FOut e -> do
        xs <- evalExpr sc e >>= strList "field out"
        pure acc {aOuts = xs : aOuts acc}
      FIn e -> do
        xs <- evalExpr sc e >>= strList "field in"
        pure acc {aIns = xs : aIns acc}
      FAfter e -> do
        xs <- evalExpr sc e >>= strList "field after"
        pure acc {aAfter = xs : aAfter acc}
      FCost e -> do
        when (aCost acc /= Nothing) (throwError (EStepField "duplicate cost"))
        v <- evalExpr sc e
        case v of
          VInt n
            | n < 0 -> throwError (EArg "field" "cost" "negative")
            | otherwise -> pure acc {aCost = Just n}
          _ -> typeErr "field cost" "int" v
      FDepfile e -> do
        when (aDepfile acc /= Nothing) (throwError (EStepField "duplicate depfile"))
        v <- evalExpr sc e
        case v of
          VStr s -> pure acc {aDepfile = Just s}
          _ -> typeErr "field depfile" "str" v
      FCmd name argEs -> do
        when (aCmd acc /= Nothing) (throwError (EStepField "duplicate cmd"))
        c <- maybe (throwError (EUnknownCmd name)) pure (lookupCommand name)
        vs <- mapM (evalExpr sc) argEs
        let spec = cmdSpec c
        when (length vs /= length (csArgs spec)) $
          throwError (EArity "cmd" name (renderInt (length (csArgs spec))) (length vs))
        args <- forM (zip3 [1 :: Int ..] (csArgs spec) vs) $ \(i, ty, v) ->
          let site = B.concat ["cmd ", name, " argument ", renderInt i]
           in case (ty, v) of
                (ArgTyStr, VStr s) -> pure (ArgStr s)
                (ArgTyInt, VInt n) -> pure (ArgInt n)
                (ArgTyStr, _) -> typeErr site "str" v
                (ArgTyInt, _) -> typeErr site "int" v
        pure acc {aCmd = Just (Command c args)}
