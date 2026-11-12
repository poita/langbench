-- | Interpreter for bound expressions.
module MiniSQL.Eval
  ( Env (..)
  , rowEnv
  , eval
  , isTrue
  ) where

import Data.Array ((!))

import MiniSQL.Bound
import MiniSQL.Like
import MiniSQL.Syntax
import MiniSQL.Value

-- | What an expression is evaluated against.
data Env = Env
  { envRow :: Row
  -- ^ The current row; for a group, its representative (first) row.
  , envGroup :: [Row]
  -- ^ The rows of the group that aggregates range over.
  }

-- | An environment for plain per-row evaluation.
rowEnv :: Row -> Env
rowEnv r = Env r []

-- | Is the expression true in boolean context (NULL and 0 are not)?
isTrue :: Env -> BExpr -> Bool
isTrue env e = truth (eval env e) == Just True

-- | Evaluate a bound expression.
eval :: Env -> BExpr -> Value
eval env = go
  where
    row = envRow env
    go e = case e of
      BLit v -> v
      BCol i -> row ! i
      BNeg a -> case go a of
        VInt n -> VInt (negate n)
        _ -> VNull
      BArith op a b -> arith op (go a) (go b)
      BCmp op a b -> case (go a, go b) of
        (VNull, _) -> VNull
        (_, VNull) -> VNull
        (x, y) -> fromBool (cmp op (compareValues x y))
      BAnd a b -> case (truth (go a), truth (go b)) of
        (Just False, _) -> fromBool False
        (_, Just False) -> fromBool False
        (Just True, Just True) -> fromBool True
        _ -> VNull
      BOr a b -> case (truth (go a), truth (go b)) of
        (Just True, _) -> fromBool True
        (_, Just True) -> fromBool True
        (Just False, Just False) -> fromBool False
        _ -> VNull
      BNot a -> maybe VNull (fromBool . not) (truth (go a))
      BIsNull a -> fromBool (go a == VNull)
      BLike a b -> case (go a, go b) of
        (VNull, _) -> VNull
        (_, VNull) -> VNull
        (s, p) -> fromBool (likeMatch (renderValue p) (renderValue s))
      BAgg Count Nothing -> VInt (length (envGroup env))
      BAgg fn Nothing -> aggregate fn []
      BAgg fn (Just a) -> aggregate fn [eval (rowEnv r) a | r <- envGroup env]

cmp :: CmpOp -> Ordering -> Bool
cmp op o = case op of
  Eq -> o == EQ
  Ne -> o /= EQ
  Lt -> o == LT
  Le -> o /= GT
  Gt -> o == GT
  Ge -> o /= LT

-- | Integer arithmetic; division and remainder by zero give NULL. Operands
-- that are not integers are outside the specification and give NULL.
arith :: ArithOp -> Value -> Value -> Value
arith op (VInt a) (VInt b) = case op of
  Add -> VInt (a + b)
  Sub -> VInt (a - b)
  Mul -> VInt (a * b)
  Div
    | b == 0 -> VNull
    | b == -1 -> VInt (negate a)
    | otherwise -> VInt (a `quot` b)
  Mod
    | b == 0 -> VNull
    | b == -1 -> VInt 0
    | otherwise -> VInt (a `rem` b)
arith _ _ _ = VNull

-- | Fold one aggregate over the per-row argument values of a group.
aggregate :: AggFn -> [Value] -> Value
aggregate fn args = case fn of
  Count -> VInt (length vals)
  Sum -> if null ints then VNull else VInt (sum ints)
  Min -> extreme LT
  Max -> extreme GT
  Avg
    | null ints -> VNull
    | otherwise ->
        let s = sum ints
            c = length ints
            h = (200 * abs s + c) `div` (2 * c)
         in VReal (if s < 0 then negate h else h)
  where
    vals = filter (/= VNull) args
    ints = [n | VInt n <- vals]
    extreme want = case vals of
      [] -> VNull
      (v : vs) -> foldl' (\m x -> if compareValues x m == want then x else m) v vs
