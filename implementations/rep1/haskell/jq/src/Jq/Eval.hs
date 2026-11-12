-- | A lazy tree-walking evaluator for filters.
module Jq.Eval
  ( Env
  , eval
  , evalStream
  ) where

import Data.Foldable (toList)
import qualified Data.Map.Strict as M
import qualified Data.Sequence as Seq
import Jq.Ops
import Jq.Stream
import Jq.Syntax
import Jq.Value

-- | Variable bindings (a persistent map: binding is O(log n) and shares the
-- rest of the environment).
type Env = M.Map String Value

-- | Evaluate a filter against an input in the empty environment.
evalStream :: Expr -> Value -> Stream Value
evalStream = eval M.empty

liftMaybe :: Maybe a -> Stream a
liftMaybe = maybe Failed single

-- | Evaluate a filter.  The result is lazy: outputs can be consumed one by
-- one, and an error only surfaces when the stream reaches it.
eval :: Env -> Expr -> Value -> Stream Value
eval env expr v = case expr of
  Identity -> single v
  Literal x -> single x
  Variable n -> liftMaybe (M.lookup n env)
  Pipe a b -> eval env a v >>= eval env b
  Comma a b -> eval env a v `appendS` eval env b v
  Negate e -> eval env e v >>= \x -> case x of
    VNumber n -> single (VNumber (negate n))
    _ -> Failed
  Binary op a b ->
    eval env b v >>= \y -> eval env a v >>= \x -> liftMaybe (binaryOp op x y)
  And a b -> eval env a v >>= \x ->
    if truthy x
      then eval env b v >>= single . VBool . truthy
      else single (VBool False)
  Or a b -> eval env a v >>= \x ->
    if truthy x
      then single (VBool True)
      else eval env b v >>= single . VBool . truthy
  ArrayOf Nothing -> single (VArray Seq.empty)
  ArrayOf (Just e) -> liftMaybe (VArray . Seq.fromList <$> collectS (eval env e v)) >>= single
  ObjectOf entries -> buildObject entries emptyObject
  If c a b -> eval env c v >>= \x -> if truthy x then eval env a v else eval env b v
  Bind e name body -> eval env e v >>= \x -> eval (M.insert name x env) body v
  Reduce src name ini upd -> eval env ini v >>= \i -> reduceLoop name upd i (eval env src v)
  Index t k tol ->
    eval env k v >>= \kv -> eval env t v >>= \tv -> case indexValue tv kv of
      Just r -> single r
      Nothing -> failUnless tol
  Iterate t tol -> eval env t v >>= \tv -> case iterateValue tv of
    Just xs -> fromList xs
    Nothing -> failUnless tol
  Slice t lo hi tol ->
    optional' lo >>= \l -> optional' hi >>= \h -> eval env t v >>= \tv ->
      case sliceValue tv l h of
        Just r -> single r
        Nothing -> failUnless tol
  Try e -> tryS (eval env e v)
  Call0 b -> call0 b v
  Call1 b f -> call1 env b f v
  where
    optional' Nothing = single Nothing
    optional' (Just e) = Just <$> eval env e v

    buildObject [] o = single (VObject o)
    buildObject ((ke, ve) : rest) o =
      eval env ke v >>= \k -> case k of
        VString s -> eval env ve v >>= \x -> buildObject rest (objInsert s x o)
        _ -> Failed

    reduceLoop name upd = go
      where
        go acc s = case s of
          Done -> single acc
          Failed -> Failed
          x :> r -> case lastS (eval (M.insert name x env) upd acc) of
            Nothing -> Failed
            Just Nothing -> go VNull r
            Just (Just acc') -> go acc' r

failUnless :: Bool -> Stream a
failUnless tolerant = if tolerant then Done else Failed

call0 :: Builtin0 -> Value -> Stream Value
call0 b v = case b of
  Empty -> Done
  Error -> Failed
  Not -> single (VBool (not (truthy v)))
  Length -> liftMaybe (lengthValue v)
  Keys -> liftMaybe (keysValue v)
  Type -> single (VString (typeName v))
  AddAll -> liftMaybe (addValues v)
  Reverse -> liftMaybe (reverseValue v)
  Sort -> liftMaybe (sortValues v)
  Unique -> liftMaybe (uniqueValues v)
  Min -> liftMaybe (minValue v)
  Max -> liftMaybe (maxValue v)
  ToString -> single (toStringValue v)
  ToNumber -> liftMaybe (toNumberValue v)

call1 :: Env -> Builtin1 -> Expr -> Value -> Stream Value
call1 env b f v = case b of
  Select -> eval env f v >>= \c -> if truthy c then single v else Done
  Map -> case iterateValue v of
    Nothing -> Failed
    Just xs -> case collectS (fromList xs >>= eval env f) of
      Nothing -> Failed
      Just ys -> single (VArray (Seq.fromList ys))
  SortBy -> case v of
    VArray a -> case keyed a of
      Nothing -> Failed
      Just ks -> single (VArray (Seq.fromList (sortByKeys ks)))
    _ -> Failed
  GroupBy -> case v of
    VArray a -> case keyed a of
      Nothing -> Failed
      Just ks -> single (VArray (Seq.fromList (map (VArray . Seq.fromList) (groupByKeys ks))))
    _ -> Failed
  Has -> eval env f v >>= \k -> liftMaybe (hasKey v k)
  ErrorWith -> case firstS (eval env f v) of
    Just Nothing -> Done
    _ -> Failed
  where
    keyed a = traverse (\x -> (\ks -> (ks, x)) <$> collectS (eval env f x)) (toList a)
