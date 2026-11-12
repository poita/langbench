-- | Pure operations on values: arithmetic, comparison, indexing, slicing.
-- Failures are reported as @Left message@.
module Jq.Ops
  ( binop
  , negateValue
  , indexValue
  , sliceValue
  , iterateValue
  , addValues
  , lengthValue
  , keysValue
  , hasValue
  , toStringValue
  , toNumberValue
  ) where

import qualified Data.ByteString as B
import Data.Foldable (toList)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE

import Jq.Json.Encoder (renderValueText)
import Jq.Number (scanNumber)
import Jq.Syntax (BinOp (..))
import Jq.Value

type R a = Either Text a

typeErr :: Text -> Value -> Text -> Value -> R a
typeErr what a op b = Left (typeName a <> " and " <> typeName b <> " cannot be " <> what <> " (" <> op <> ")")

-- | Apply a binary operator.
binop :: BinOp -> Value -> Value -> R Value
binop op a b = case op of
  Add -> plus a b
  Sub -> minus a b
  Mul -> times a b
  Div -> divide a b
  Mod -> modulo a b
  Eq -> Right (VBool (compareValues a b == EQ))
  Ne -> Right (VBool (compareValues a b /= EQ))
  Lt -> Right (VBool (compareValues a b == LT))
  Le -> Right (VBool (compareValues a b /= GT))
  Gt -> Right (VBool (compareValues a b == GT))
  Ge -> Right (VBool (compareValues a b /= LT))

plus :: Value -> Value -> R Value
plus VNull x = Right x
plus x VNull = Right x
plus (VNum x) (VNum y) = Right (VNum (x + y))
plus (VStr x) (VStr y) = Right (VStr (x <> y))
plus (VArr x) (VArr y) = Right (VArr (x Seq.>< y))
plus (VObj x) (VObj y) = Right (VObj (mergeShallow x y))
plus a b = typeErr "added" a "+" b

-- | @a@ with every entry of @b@ set in order.
mergeShallow :: Object -> Object -> Object
mergeShallow x y = foldl (\o (k, v) -> objectInsert k v o) x (objectToList y)

mergeDeep :: Object -> Object -> Object
mergeDeep x y = foldl step x (objectToList y)
  where
    step o (k, v) = case (objectLookup k o, v) of
      (Just (VObj l), VObj r) -> objectInsert k (VObj (mergeDeep l r)) o
      _ -> objectInsert k v o

minus :: Value -> Value -> R Value
minus (VNum x) (VNum y) = Right (VNum (x - y))
minus (VArr x) (VArr y) =
  let s = Set.fromList (toList y)
  in Right (VArr (Seq.filter (`Set.notMember` s) x))
minus a b = typeErr "subtracted" a "-" b

times :: Value -> Value -> R Value
times (VNum x) (VNum y) = Right (VNum (x * y))
times (VStr s) (VNum n) = Right (repeatStr s n)
times (VNum n) (VStr s) = Right (repeatStr s n)
times (VObj x) (VObj y) = Right (VObj (mergeDeep x y))
times a b = typeErr "multiplied" a "*" b

repeatStr :: Text -> Double -> Value
repeatStr s n
  | n < 0 || isNaN n = VNull
  | otherwise = VStr (T.replicate (truncate (min n 1e9)) s)

divide :: Value -> Value -> R Value
divide (VNum x) (VNum y)
  | y == 0 = Left "number and number cannot be divided because the divisor is zero"
  | otherwise = Right (VNum (x / y))
divide (VStr x) (VStr y) = Right (VArr (Seq.fromList (map VStr (splitStr x y))))
divide a b = typeErr "divided" a "/" b

splitStr :: Text -> Text -> [Text]
splitStr s sep
  | T.null s = []
  | T.null sep = map T.singleton (T.unpack s)
  | otherwise = T.splitOn sep s

modulo :: Value -> Value -> R Value
modulo (VNum x) (VNum y)
  | isNaN x || isNaN y = Right (VNum (0 / 0))
  | yi == 0 = Left "number and number cannot be divided because the divisor is zero"
  | otherwise = Right (VNum (fromInteger (xi `rem` yi)))
  where
    xi = truncate x :: Integer
    yi = truncate y :: Integer
modulo a b = typeErr "divided" a "%" b

negateValue :: Value -> R Value
negateValue (VNum x) = Right (VNum (negate x))
negateValue v = Left (typeName v <> " cannot be negated")

-- | @t[k]@ for a single key.
indexValue :: Value -> Value -> R Value
indexValue t k = case (t, k) of
  (VObj o, VStr s) -> Right (maybe VNull id (objectLookup s o))
  (VNull, VStr _) -> Right VNull
  (VArr xs, VNum n) -> Right (arrIndex xs n)
  (VNull, VNum _) -> Right VNull
  _ -> Left ("Cannot index " <> typeName t <> " with " <> describeKey k)
  where
    describeKey (VStr s) = "\"" <> s <> "\""
    describeKey v = typeName v

arrIndex :: Seq.Seq Value -> Double -> Value
arrIndex xs n
  | isNaN n = VNull
  | otherwise =
      let len = Seq.length xs
          t = fromIntegral (len + 1) :: Double
          i | n > t = len
            | n < negate t = negate len - 1
            | otherwise = truncate n
          j = if i < 0 then i + len else i
      in if j < 0 || j >= len then VNull else Seq.index xs j

-- | @t[a:b]@ with already-evaluated bounds (@VNull@ means absent).
sliceValue :: Value -> Value -> Value -> R Value
sliceValue t a b = case t of
  VNull -> Right VNull
  VArr xs -> do (i, j) <- bounds (Seq.length xs); Right (VArr (Seq.take (j - i) (Seq.drop i xs)))
  VStr s -> do (i, j) <- bounds (T.length s); Right (VStr (T.take (j - i) (T.drop i s)))
  _ -> Left ("Cannot index " <> typeName t <> " with object")
  where
    bounds len = do
      lo <- bound (fromIntegral len) 0 floor a
      hi <- bound (fromIntegral len) (fromIntegral len) ceiling b
      let i = clamp len lo
          j = max i (clamp len hi)
      Right (i, j)
    bound :: Double -> Double -> (Double -> Integer) -> Value -> R Double
    bound len dflt rnd v = case v of
      VNull -> Right dflt
      VNum n | isNaN n -> Right dflt
             | otherwise -> let r = fromInteger (rnd (max (-1e18) (min 1e18 n))) :: Double
                            in Right (if r < 0 then r + len else r)
      _ -> Left "Start and end indices of an array slice must be numbers"
    clamp len d = if d < 0 then 0 else if d > fromIntegral len then len else truncate d

-- | The elements of an iterable value (object values in insertion order).
iterateValue :: Value -> R [Value]
iterateValue v = case v of
  VArr xs -> Right (toList xs)
  VObj o -> Right (objectValues o)
  _ -> Left ("Cannot iterate over " <> typeName v)

-- | @add@: sum with @+@ starting from @null@; linear in total size.
addValues :: [Value] -> R Value
addValues xs0 = case filter notNull xs0 of
  [] -> Right VNull
  xs@(VStr _ : _) | Just ss <- mapM str xs -> Right (VStr (T.concat ss))
  xs@(VArr _ : _) | Just as <- mapM arr xs -> Right (VArr (mconcat as))
  (x : xs) -> go x xs
  where
    notNull VNull = False
    notNull _ = True
    str (VStr s) = Just s
    str _ = Nothing
    arr (VArr a) = Just a
    arr _ = Nothing
    go acc [] = Right acc
    go acc (y : ys) = plus acc y >>= \a -> go a ys

lengthValue :: Value -> R Value
lengthValue v = case v of
  VNull -> Right (VNum 0)
  VNum n -> Right (VNum (abs n))
  VStr s -> Right (VNum (fromIntegral (T.length s)))
  VArr xs -> Right (VNum (fromIntegral (Seq.length xs)))
  VObj o -> Right (VNum (fromIntegral (objectSize o)))
  VBool _ -> Left "boolean has no length"

keysValue :: Value -> R Value
keysValue v = case v of
  VObj o -> Right (VArr (Seq.fromList (map VStr (objectSortedKeys o))))
  VArr xs -> Right (VArr (Seq.fromList (map (VNum . fromIntegral) [0 .. Seq.length xs - 1])))
  _ -> Left (typeName v <> " has no keys")

hasValue :: Value -> Value -> R Value
hasValue t k = case (t, k) of
  (VObj o, VStr s) -> Right (VBool (objectMember s o))
  (VArr xs, VNum n) -> Right (VBool (n > -1 && n < fromIntegral (Seq.length xs)))
  (VNull, _) -> Right (VBool False)
  _ -> Left ("Cannot check whether " <> typeName t <> " has a " <> typeName k <> " key")

toStringValue :: Value -> Value
toStringValue v@(VStr _) = v
toStringValue v = VStr (renderValueText v)

toNumberValue :: Value -> R Value
toNumberValue v = case v of
  VNum _ -> Right v
  VStr s ->
    let bs = TE.encodeUtf8 s
    in case scanNumber bs 0 of
         Just (d, e) | e == B.length bs -> Right (VNum d)
         _ -> Left ("Cannot parse '" <> s <> "' as a number")
  _ -> Left (typeName v <> " cannot be parsed as a number")
