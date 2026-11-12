-- | A deliberately naive reference evaluator used as a test oracle.
--
-- It evaluates level by level (the caller supplies a stratum level per
-- predicate), re-applying every rule to the full relations until nothing
-- new appears. It shares no code with the real engine.
module Reference (referenceModel) where

import Control.Monad (foldM)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Datalog.Syntax

type Db = M.Map Predicate (S.Set [Const])
type Env = M.Map String Const

-- | The model as predicate → set of tuples. Positive atoms must precede
-- the negations and comparisons that use their variables.
referenceModel :: (Predicate -> Int) -> Program -> Db
referenceModel level prog = foldl stratum M.empty levels
  where
    rules = progRules prog
    levels = S.toAscList (S.fromList (map (level . atomPredicate . ruleHead) rules))
    stratum db l = fixpoint db [r | r <- rules, level (atomPredicate (ruleHead r)) == l]
    fixpoint db rs =
      let db' = foldl (\d r -> foldl insert d (derive d r)) db rs
      in if db' == db then db else fixpoint db' rs
    insert d (p, t) = M.insertWith S.union p (S.singleton t) d

derive :: Db -> Rule -> [(Predicate, [Const])]
derive db (Rule h body) =
  [ (atomPredicate h, map (value env) (atomArgs h)) | env <- foldM step M.empty body ]
  where
    step env lit = case lit of
      Pos a -> [env' | t <- S.toList (rel a), Just env' <- [unify env (atomArgs a) t]]
      Neg a -> [env | map (value env) (atomArgs a) `S.notMember` rel a]
      Cmp op x y -> [env | holds op (value env x) (value env y)]
    rel a = M.findWithDefault S.empty (atomPredicate a) db

unify :: Env -> [Term] -> [Const] -> Maybe Env
unify env [] [] = Just env
unify env (t : ts) (c : cs) = case t of
  TConst k -> if k == c then unify env ts cs else Nothing
  TAnon -> unify env ts cs
  TVar v -> case M.lookup v env of
    Just k -> if k == c then unify env ts cs else Nothing
    Nothing -> unify (M.insert v c env) ts cs
unify _ _ _ = Nothing

value :: Env -> Term -> Const
value _ (TConst c) = c
value env (TVar v) = env M.! v
value _ TAnon = error "anonymous variable has no value"

holds :: CmpOp -> Const -> Const -> Bool
holds op x y = case op of
  OpLt -> x < y
  OpLe -> x <= y
  OpGt -> x > y
  OpGe -> x >= y
  OpEq -> x == y
  OpNe -> x /= y
