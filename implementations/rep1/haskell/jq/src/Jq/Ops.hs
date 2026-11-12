-- | Pure value-level operations behind operators and builtins.
--
-- Functions returning 'Maybe' use 'Nothing' for a jq runtime error.
module Jq.Ops
  ( binaryOp
  , indexValue
  , iterateValue
  , sliceValue
  , lengthValue
  , keysValue
  , hasKey
  , addValues
  , reverseValue
  , toStringValue
  , toNumberValue
  , sortValues
  , uniqueValues
  , minValue
  , maxValue
  , sortByKeys
  , groupByKeys
  ) where

import qualified Data.ByteString.Char8 as B8
import Data.Foldable (toList)
import Data.Function (on)
import Data.Int (Int64)
import Data.List (groupBy, sortBy)
import Data.Ord (comparing)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Text as T
import Jq.Json.Parse (parseJson)
import Jq.Json.Render (renderText)
import Jq.Number (truncateToInt)
import Jq.Syntax (BinOp (..))
import Jq.Value

-- | Apply a binary operator.
binaryOp :: BinOp -> Value -> Value -> Maybe Value
binaryOp op a b = case op of
  Add -> addValue a b
  Sub -> case (a, b) of
    (VNumber x, VNumber y) -> Just (VNumber (x - y))
    (VArray x, VArray y) ->
      let drop' = Set.fromList (toList y)
       in Just (VArray (Seq.filter (`Set.notMember` drop') x))
    _ -> Nothing
  Mul -> case (a, b) of
    (VNumber x, VNumber y) -> Just (VNumber (x * y))
    (VString s, VNumber n) -> Just (repeatText s n)
    (VNumber n, VString s) -> Just (repeatText s n)
    (VObject x, VObject y) -> Just (VObject (objDeepMerge x y))
    _ -> Nothing
  Div -> case (a, b) of
    (VNumber x, VNumber y) | y /= 0 -> Just (VNumber (x / y))
    (VString x, VString y) -> Just (VArray (Seq.fromList (map VString (splitText x y))))
    _ -> Nothing
  Mod -> case (a, b) of
    (VNumber x, VNumber y) ->
      let y' = toI y
       in if y' == 0 then Nothing else Just (VNumber (fromIntegral (toI x `rem` y')))
    _ -> Nothing
  Eq -> Just (VBool (a == b))
  Ne -> Just (VBool (a /= b))
  Lt -> Just (VBool (a < b))
  Le -> Just (VBool (a <= b))
  Gt -> Just (VBool (a > b))
  Ge -> Just (VBool (a >= b))
  where
    toI :: Double -> Int64
    toI = fromIntegral . truncateToInt

repeatText :: T.Text -> Double -> Value
repeatText s n
  | n < 0 = VNull
  | otherwise = VString (T.replicate (truncateToInt n) s)

splitText :: T.Text -> T.Text -> [T.Text]
splitText x sep
  | T.null x = []
  | T.null sep = map T.singleton (T.unpack x)
  | otherwise = T.splitOn sep x

addValue :: Value -> Value -> Maybe Value
addValue a b = case (a, b) of
  (VNull, x) -> Just x
  (x, VNull) -> Just x
  (VNumber x, VNumber y) -> Just (VNumber (x + y))
  (VString x, VString y) -> Just (VString (T.append x y))
  (VArray x, VArray y) -> Just (VArray (x Seq.>< y))
  (VObject x, VObject y) -> Just (VObject (objMerge x y))
  _ -> Nothing

-- | @.[k]@
indexValue :: Value -> Value -> Maybe Value
indexValue t k = case (t, k) of
  (VObject o, VString s) -> Just (maybe VNull id (objLookup s o))
  (VArray a, VNumber n) ->
    let len = Seq.length a
        i0 = truncateToInt n
        i = if i0 < 0 then i0 + len else i0
     in Just (maybe VNull id (Seq.lookup i a))
  (VNull, VString _) -> Just VNull
  (VNull, VNumber _) -> Just VNull
  _ -> Nothing

-- | @.[]@: the elements of an array or the values of an object.
iterateValue :: Value -> Maybe [Value]
iterateValue v = case v of
  VArray a -> Just (toList a)
  VObject o -> Just (objValues o)
  _ -> Nothing

-- | @.[lo:hi]@ with optional bounds (@null@ counts as absent).
sliceValue :: Value -> Maybe Value -> Maybe Value -> Maybe Value
sliceValue t lo hi = case t of
  VNull -> Just VNull
  VArray a -> do
    (s, e) <- bounds (Seq.length a)
    Just (VArray (Seq.take (e - s) (Seq.drop s a)))
  VString x -> do
    (s, e) <- bounds (T.length x)
    Just (VString (T.take (e - s) (T.drop s x)))
  _ -> Nothing
  where
    bounds len = do
      l <- bound lo
      h <- bound hi
      let len' = fromIntegral len :: Double
          norm d = max 0 (min len' (if d < 0 then d + len' else d))
          s = floor (norm (maybe 0 id l)) :: Int
          e = ceiling (norm (maybe len' id h)) :: Int
      Just (s, max s e)
    bound Nothing = Just Nothing
    bound (Just VNull) = Just Nothing
    bound (Just (VNumber n)) = Just (Just n)
    bound _ = Nothing

-- | @length@
lengthValue :: Value -> Maybe Value
lengthValue v = case v of
  VNull -> Just (VNumber 0)
  VNumber n -> Just (VNumber (abs n))
  VString s -> Just (VNumber (fromIntegral (T.length s)))
  VArray a -> Just (VNumber (fromIntegral (Seq.length a)))
  VObject o -> Just (VNumber (fromIntegral (objSize o)))
  VBool _ -> Nothing

-- | @keys@
keysValue :: Value -> Maybe Value
keysValue v = case v of
  VObject o -> Just (VArray (Seq.fromList (map VString (objKeysSorted o))))
  VArray a -> Just (VArray (Seq.fromList [VNumber (fromIntegral i) | i <- [0 .. Seq.length a - 1]]))
  _ -> Nothing

-- | @has(k)@
hasKey :: Value -> Value -> Maybe Value
hasKey t k = case (t, k) of
  (VObject o, VString s) -> Just (VBool (maybe False (const True) (objLookup s o)))
  (VArray a, VNumber n) ->
    let i = truncateToInt n in Just (VBool (i >= 0 && i < Seq.length a))
  (VNull, _) -> Just (VBool False)
  _ -> Nothing

-- | @add@: sum the elements of an array or the values of an object.
addValues :: Value -> Maybe Value
addValues v = do
  xs <- iterateValue v
  case filter notNull xs of
    [] -> Just VNull
    ys@(VString _ : _) | Just ss <- mapM str ys -> Just (VString (T.concat ss))
    ys@(VArray _ : _) | Just as <- mapM arr ys -> Just (VArray (mconcat as))
    ys@(VNumber _ : _) | Just ns <- mapM num ys -> Just (VNumber (foldl1 (+) ns))
    ys@(VObject _ : _) | Just os <- mapM obj ys -> Just (VObject (foldl1 objMerge os))
    (y : ys) -> foldlM' addValue y ys
  where
    notNull VNull = False
    notNull _ = True
    str (VString s) = Just s
    str _ = Nothing
    arr (VArray s) = Just s
    arr _ = Nothing
    num (VNumber s) = Just s
    num _ = Nothing
    obj (VObject s) = Just s
    obj _ = Nothing
    foldlM' f z = go z
      where
        go acc [] = Just acc
        go acc (y : ys) = f acc y >>= \acc' -> go acc' ys

-- | @reverse@
reverseValue :: Value -> Maybe Value
reverseValue v = case v of
  VNull -> Just (VArray Seq.empty)
  VArray a -> Just (VArray (Seq.reverse a))
  _ -> Nothing

-- | @tostring@
toStringValue :: Value -> Value
toStringValue v@(VString _) = v
toStringValue v = VString (renderText v)

-- | @tonumber@
toNumberValue :: Value -> Maybe Value
toNumberValue v = case v of
  VNumber _ -> Just v
  VString s
    | validNumber (T.unpack s) -> case parseJson (B8.pack (T.unpack s)) of
        Right n@(VNumber _) -> Just n
        _ -> Nothing
  _ -> Nothing
  where
    validNumber str = case str of
      [] -> False
      _ -> all (`elem` ("0123456789+-.eE" :: String)) str && any (`elem` ("0123456789" :: String)) str

-- | @sort@
sortValues :: Value -> Maybe Value
sortValues (VArray a) = Just (VArray (Seq.fromList (sortBy compare (toList a))))
sortValues _ = Nothing

-- | @unique@
uniqueValues :: Value -> Maybe Value
uniqueValues (VArray a) = Just (VArray (Seq.fromList (dedupe (sortBy compare (toList a)))))
  where
    dedupe (x : y : r) | x == y = dedupe (x : r)
    dedupe (x : r) = x : dedupe r
    dedupe [] = []
uniqueValues _ = Nothing

-- | @min@: the first minimal element.
minValue :: Value -> Maybe Value
minValue (VArray a) = Just (case toList a of
  [] -> VNull
  (x : xs) -> foldl' (\m y -> if y < m then y else m) x xs)
minValue _ = Nothing

-- | @max@: the last maximal element.
maxValue :: Value -> Maybe Value
maxValue (VArray a) = Just (case toList a of
  [] -> VNull
  (x : xs) -> foldl' (\m y -> if y >= m then y else m) x xs)
maxValue _ = Nothing

-- | Stable sort of elements by precomputed keys.
sortByKeys :: [([Value], Value)] -> [Value]
sortByKeys = map snd . sortBy (comparing fst)

-- | Group elements by precomputed keys, groups in ascending key order.
groupByKeys :: [([Value], Value)] -> [[Value]]
groupByKeys = map (map snd) . groupBy ((==) `on` fst) . sortBy (comparing fst)
