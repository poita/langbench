-- | Algorithm J: single-pass inference that unifies as it goes.
module Language.TypeInfer.Infer
  ( DeclResult (..)
  , inferProgram
  , inferExpr
  ) where

import Control.Monad (forM, forM_)
import Control.Monad.ST (ST, runST)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M

import Language.TypeInfer.Builtins
import Language.TypeInfer.Error
import Language.TypeInfer.Graph
import Language.TypeInfer.Syntax
import Language.TypeInfer.Type
import Language.TypeInfer.Unify

-- | The outcome of one top-level declaration.
data DeclResult = DeclResult
  { resultName :: Maybe Name
    -- ^ The bound name; 'Nothing' for a bare expression.
  , resultType :: Either TypeError Type
    -- ^ The principal type, or why inference failed.
  }
  deriving (Eq, Show)

-- | Typing environment: innermost binding of each name.
type Env s = Map Name (Scheme s)

initialEnv :: Ctx s -> ST s (Env s)
initialEnv ctx = M.fromList <$> forM builtinTypes (\(n, t) -> (,) n <$> importScheme ctx t)

-- | Infer every declaration in order. A declaration that fails is reported
-- and leaves the environment unchanged; later declarations are still
-- processed.
inferProgram :: Program -> [DeclResult]
inferProgram decls = runST $ do
  ctx <- newCtx
  env0 <- initialEnv ctx
  let go _ [] = pure []
      go env (d : ds) = do
        r <- runExceptT (inferDecl ctx env d)
        case r of
          Left err -> (DeclResult (declName d) (Left err) :) <$> go env ds
          Right (ty, env') -> (DeclResult (declName d) (Right ty) :) <$> go env' ds
  go env0 decls

-- | The principal type of an expression in the initial environment.
inferExpr :: Expr -> Either TypeError Type
inferExpr e = case inferProgram [DExpr e] of
  [r] -> resultType r
  _ -> Left Unify  -- unreachable: one declaration yields one result

-- | Top-level declarations are inferred at level 1 against an environment
-- whose schemes are closed, and generalised relative to level 0.
inferDecl :: Ctx s -> Env s -> Decl -> Infer s (Type, Env s)
inferDecl ctx env = \case
  DExpr e -> do
    t <- infer ctx env 1 e
    ty <- lift (freeze ctx t)
    pure (ty, env)
  DLet x e -> do
    t <- infer ctx env 1 e
    sch <- lift (generalise ctx 0 t)
    ty <- lift (freeze ctx t)
    pure (ty, M.insert x sch env)
  DLetRec f p body -> do
    (t, sch) <- inferRec ctx env 0 f p body
    ty <- lift (freeze ctx t)
    pure (ty, M.insert f sch env)

-- | Infer @let rec f p = body@ whose enclosing level is @lvl@. Returns the
-- type of @f@ and its generalisation.
inferRec :: Ctx s -> Env s -> Level -> Name -> Name -> Expr -> Infer s (Ty s, Scheme s)
inferRec ctx env lvl f p body = do
  tf <- lift (freshVar ctx (lvl + 1))
  t <- infer ctx (M.insert f (Mono tf) env) (lvl + 1) (EFun p body)
  unify ctx tf t
  sch <- lift (generalise ctx lvl tf)
  pure (tf, sch)

infer :: Ctx s -> Env s -> Level -> Expr -> Infer s (Ty s)
infer ctx env lvl = go env
  where
    go en = \case
      EVar x -> case M.lookup x en of
        Nothing -> throwE (Unbound x)
        Just sch -> lift (instantiate ctx lvl sch)
      ELit (LInt _) -> pure TyInt
      ELit (LBool _) -> pure TyBool
      ELit LUnit -> pure TyUnit
      EApp f a -> do
        tf <- go en f
        ta <- go en a
        r <- lift (freshVar ctx lvl)
        fn <- lift (mkFun ta r)
        unify ctx tf fn
        pure r
      EFun x b -> do
        tv <- lift (freshVar ctx lvl)
        tb <- go (M.insert x (Mono tv) en) b
        lift (mkFun tv tb)
      ELet x e1 e2 -> do
        t1 <- infer ctx en (lvl + 1) e1
        sch <- lift (generalise ctx lvl t1)
        go (M.insert x sch en) e2
      ELetRec f p e1 e2 -> do
        (_, sch) <- inferRec ctx en lvl f p e1
        go (M.insert f sch en) e2
      EIf c a b -> do
        tc <- go en c
        unify ctx tc TyBool
        ta <- go en a
        tb <- go en b
        unify ctx ta tb
        pure ta
      ETuple es -> mapM (go en) es >>= lift . mkTuple
      EList es -> do
        el <- lift (freshVar ctx lvl)
        forM_ es $ \e -> go en e >>= unify ctx el
        lift (mkList el)
      ECons a b -> do
        ta <- go en a
        tb <- go en b
        tl <- lift (mkList ta)
        unify ctx tb tl
        pure tl
      EBin op a b -> do
        let (operand, result) = opTypes op
        ta <- go en a
        unify ctx ta operand
        tb <- go en b
        unify ctx tb operand
        pure result

-- | Operand and result type of a binary operator.
opTypes :: BinOp -> (Ty s, Ty s)
opTypes = \case
  Add -> ints TyInt
  Sub -> ints TyInt
  Mul -> ints TyInt
  Div -> ints TyInt
  Eq -> ints TyBool
  Lt -> ints TyBool
  Gt -> ints TyBool
  Le -> ints TyBool
  Ge -> ints TyBool
  And -> (TyBool, TyBool)
  Or -> (TyBool, TyBool)
  where
    ints r = (TyInt, r)
