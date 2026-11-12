-- | The builtin functions.
module Jq.Builtins
  ( callBuiltin
  ) where

import Data.Foldable (toList)
import Data.List (sortBy)
import qualified Data.Sequence as Seq
import Data.Text (Text)

import Jq.Ops
import Jq.Stream
import Jq.Syntax (Expr)
import Jq.Value

-- | @callBuiltin ev name args input@ runs a builtin. @ev@ evaluates an
-- argument filter against a value in the caller's environment.
callBuiltin :: (Expr -> Value -> Stream) -> Text -> [Expr] -> Value -> Stream
callBuiltin ev name args v = case (name, args) of
  ("empty", []) -> Nil
  ("error", []) -> failS "error"
  ("error", [f]) -> case ev f v of
    Nil -> Nil
    Err m -> Err m
    Cons _ _ -> failS "error"
  ("not", []) -> single (VBool (not (isTruthy v)))
  ("length", []) -> lift (lengthValue v)
  ("keys", []) -> lift (keysValue v)
  ("has", [f]) -> bindS (ev f v) (\k -> lift (hasValue v k))
  ("type", []) -> single (VStr (typeName v))
  ("add", []) -> lift (iterateValue v >>= addValues)
  ("select", [f]) -> bindS (ev f v) (\c -> if isTruthy c then single v else Nil)
  ("map", [f]) -> case iterateValue v of
    Left m -> failS m
    Right xs -> case collect (bindS (fromList xs) (ev f)) of
      Left m -> failS m
      Right ys -> single (VArr (Seq.fromList ys))
  ("sort", []) -> withArray v (\xs -> single (VArr (Seq.fromList (sortBy compareValues (toList xs)))))
  ("sort_by", [f]) -> withKeyed f v (\kxs -> single (arr (map snd (sortKeyed kxs))))
  ("group_by", [f]) -> withKeyed f v (\kxs -> single (arr (map (arr . map snd) (groupKeyed (sortKeyed kxs)))))
  ("unique", []) -> withArray v (\xs -> single (arr (dedupe (sortBy compareValues (toList xs)))))
  ("reverse", []) -> case v of
    VArr xs -> single (VArr (Seq.reverse xs))
    VNull -> single (VArr Seq.empty)
    _ -> failS ("Cannot reverse " <> typeName v)
  ("min", []) -> withArray v (\xs -> single (extreme (\x y -> compareValues y x == LT) (toList xs)))
  ("max", []) -> withArray v (\xs -> single (extreme (\x y -> compareValues y x /= LT) (toList xs)))
  ("tostring", []) -> single (toStringValue v)
  ("tonumber", []) -> lift (toNumberValue v)
  _ -> failS ("unknown builtin " <> name <> "/" <> showArity (length args))
  where
    arr = VArr . Seq.fromList
    lift = either failS single
    showArity n = if n == 0 then "0" else if n == 1 then "1" else "n"

    withArray (VArr xs) k = k xs
    withArray x _ = failS (typeName x <> " cannot be sorted, as it is not an array")

    -- Pair each element with its key @[f]@ (evaluated exactly once).
    withKeyed f (VArr xs) k = case mapM (\x -> fmap (\ys -> (arr ys, x)) (collect (ev f x))) (toList xs) of
      Left m -> failS m
      Right kxs -> k kxs
    withKeyed _ x _ = failS (typeName x <> " cannot be sorted, as it is not an array")

    sortKeyed = sortBy (\(a, _) (b, _) -> compareValues a b)

    groupKeyed [] = []
    groupKeyed ((k, x) : rest) =
      let (same, others) = span (\(k', _) -> compareValues k k' == EQ) rest
      in ((k, x) : same) : groupKeyed others

    dedupe (x : y : rest) | compareValues x y == EQ = dedupe (x : rest)
                          | otherwise = x : dedupe (y : rest)
    dedupe xs = xs

    -- @pick best acc@ keeps the new element when @pick acc new@ holds.
    extreme _ [] = VNull
    extreme replaceIf (x : xs) = foldl (\a y -> if replaceIf a y then y else a) x xs
