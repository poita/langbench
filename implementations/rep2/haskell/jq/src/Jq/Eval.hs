-- | The tree-walking evaluator.
--
-- Each expression maps an input value to a lazy 'Stream' of outputs; the
-- nesting order of generators follows jq (right operand outermost for binary
-- operators, key before target for indexing, ...).
module Jq.Eval
  ( Env
  , emptyEnv
  , eval
  , evalTop
  ) where

import qualified Data.Map.Strict as M
import qualified Data.Sequence as Seq
import Data.Text (Text)

import Jq.Builtins
import Jq.Ops
import Jq.Stream
import Jq.Syntax
import Jq.Value

-- | Variable bindings (persistent, so binding is O(log n) and shares).
type Env = M.Map Text Value

emptyEnv :: Env
emptyEnv = M.empty

-- | Evaluate a filter against an input value in the empty environment.
evalTop :: Expr -> Value -> Stream
evalTop = eval emptyEnv

-- | Evaluate in a given environment.
eval :: Env -> Expr -> Value -> Stream
eval env expr v = case expr of
  Identity -> single v
  Literal x -> single x
  Var n -> maybe (failS ("$" <> n <> " is not defined")) single (M.lookup n env)
  Index t k opt ->
    bindS (eval env k v) $ \kv ->
      bindS (eval env t v) $ \tv -> tolerant opt (indexValue tv kv)
  Iterate t opt ->
    bindS (eval env t v) $ \tv -> case iterateValue tv of
      Right xs -> fromList xs
      Left m -> if opt then Nil else failS m
  Slice t ma mb opt ->
    bindS (bound ma) $ \a ->
      bindS (bound mb) $ \b ->
        bindS (eval env t v) $ \tv -> tolerant opt (sliceValue tv a b)
  Try e -> tryS (eval env e v)
  Pipe a b -> bindS (eval env a v) (eval env b)
  Comma a b -> eval env a v `append` eval env b v
  Neg e -> bindS (eval env e v) (either failS single . negateValue)
  Binop op a b ->
    bindS (eval env b v) $ \bv ->
      bindS (eval env a v) $ \av -> either failS single (binop op av bv)
  And a b -> bindS (eval env a v) $ \av ->
    if isTruthy av then bindS (eval env b v) (single . VBool . isTruthy) else single (VBool False)
  Or a b -> bindS (eval env a v) $ \av ->
    if isTruthy av then single (VBool True) else bindS (eval env b v) (single . VBool . isTruthy)
  ArrayCons Nothing -> single (VArr Seq.empty)
  ArrayCons (Just e) -> either failS (single . VArr . Seq.fromList) (collect (eval env e v))
  ObjectCons es -> construct es emptyObject
  If c a mb -> bindS (eval env c v) $ \cv ->
    if isTruthy cv then eval env a v else maybe (single v) (\b -> eval env b v) mb
  Bind src x body -> bindS (eval env src v) $ \sv -> eval (M.insert x sv env) body v
  Reduce src x ini upd -> bindS (eval env ini v) $ \i -> reduceLoop x upd i (eval env src v)
  Call name args -> callBuiltin (eval env) name args v
  where
    tolerant opt r = case r of
      Right x -> single x
      Left m -> if opt then Nil else failS m
    bound Nothing = single VNull
    bound (Just e) = eval env e v
    construct [] o = single (VObj o)
    construct ((ke, ve) : rest) o =
      bindS (eval env ke v) $ \kv -> case kv of
        VStr k -> bindS (eval env ve v) $ \x -> construct rest (objectInsert k x o)
        _ -> failS ("Object keys must be strings")
    reduceLoop x upd acc s = case s of
      Nil -> single acc
      Err m -> Err m
      Cons item rest -> case lastS (eval (M.insert x item env) upd acc) of
        Left m -> failS m
        Right r -> reduceLoop x upd (maybe VNull id r) rest
