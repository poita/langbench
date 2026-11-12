{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Pure operator semantics: truthiness, arithmetic, comparison, equality.
module Template.Ops
  ( truthy
  , negateValue
  , binary
  , compareValues
  , valuesEqual
  , Number (..)
  , asNumber
  , numCompare
  ) where

import Data.Foldable (toList)
import Data.Ratio ((%))
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Text as T

import Template.Error
import Template.Syntax (BinOp (..), CmpOp (..))
import Template.Value

foreign import ccall unsafe "math.h fmod" c_fmod :: Double -> Double -> Double

-- | A numeric operand: booleans count as integers.
data Number = NI !Integer | NF !Double

asNumber :: Value -> Maybe Number
asNumber v = case v of
  VInt n -> Just (NI n)
  VBool b -> Just (NI (if b then 1 else 0))
  VFloat d -> Just (NF d)
  _ -> Nothing

toDouble :: Number -> Double
toDouble (NI n) = fromInteger n
toDouble (NF d) = d

fromNumber :: Number -> Value
fromNumber (NI n) = VInt n
fromNumber (NF d) = VFloat d

-- | Truthiness; the undefined value has none.
truthy :: Value -> Either ErrorKind Bool
truthy v = case v of
  VUndefined -> Left ErrUndefined
  VBool b -> Right b
  VNone -> Right False
  VInt n -> Right (n /= 0)
  VFloat d -> Right (d /= 0)
  VStr t -> Right (not (T.null t))
  VList xs -> Right (not (Seq.null xs))
  VDict d -> Right (dictSize d /= 0)
  _ -> Right True

negateValue :: Value -> Either ErrorKind Value
negateValue v = case v of
  VUndefined -> Left ErrUndefined
  _ -> case asNumber v of
    Just (NI n) -> Right (VInt (negate n))
    Just (NF d) -> Right (VFloat (negate d))
    Nothing -> Left ErrType

-- | Apply an arithmetic or string operator.
binary :: BinOp -> Value -> Value -> Either ErrorKind Value
binary op a b
  | isUndefined a || isUndefined b = Left ErrUndefined
  | otherwise = case op of
      Concat -> do
        x <- display a
        y <- display b
        Right (VStr (x <> y))
      Add -> case (a, b) of
        (VStr x, VStr y) -> Right (VStr (x <> y))
        (VList x, VList y) -> Right (VList (x Seq.>< y))
        _ -> numeric (\x y -> NI (x + y)) (+)
      Sub -> numeric (\x y -> NI (x - y)) (-)
      Mul -> case (a, b) of
        (VStr s, _) | Just (NI n) <- asNumber b -> Right (repeatText s n)
        (_, VStr s) | Just (NI n) <- asNumber a -> Right (repeatText s n)
        _ -> numeric (\x y -> NI (x * y)) (*)
      Div -> case (asNumber a, asNumber b) of
        (Just x, Just y)
          | isZero y -> Left ErrType
          | NI p <- x, NI q <- y -> Right (VFloat (fromRational (p % q)))
          | otherwise -> Right (VFloat (toDouble x / toDouble y))
        _ -> Left ErrType
      FloorDiv -> case (asNumber a, asNumber b) of
        (Just x, Just y)
          | isZero y -> Left ErrType
          | NI p <- x, NI q <- y -> Right (VInt (p `div` q))
          | otherwise -> Right (VFloat (floatFloorDiv (toDouble x) (toDouble y)))
        _ -> Left ErrType
      Mod -> case (asNumber a, asNumber b) of
        (Just x, Just y)
          | isZero y -> Left ErrType
          | NI p <- x, NI q <- y -> Right (VInt (p `mod` q))
          | otherwise -> Right (VFloat (floatMod (toDouble x) (toDouble y)))
        _ -> Left ErrType
      Pow -> case (asNumber a, asNumber b) of
        (Just (NI p), Just (NI q))
          | q >= 0 -> Right (VInt (p ^ q))
          | p == 0 -> Left ErrType
          | otherwise -> Right (VFloat (fromInteger p ** fromInteger q))
        (Just x, Just y)
          | toDouble x == 0 && toDouble y < 0 -> Left ErrType
          | otherwise -> Right (VFloat (toDouble x ** toDouble y))
        _ -> Left ErrType
  where
    numeric fi ff = case (asNumber a, asNumber b) of
      (Just (NI x), Just (NI y)) -> Right (fromNumber (fi x y))
      (Just x, Just y) -> Right (VFloat (ff (toDouble x) (toDouble y)))
      _ -> Left ErrType
    isZero (NI 0) = True
    isZero (NF d) = d == 0
    isZero _ = False
    repeatText s n = VStr (if n <= 0 then T.empty else T.replicate (fromInteger n) s)

-- Python's float floor division and modulo.
floatMod :: Double -> Double -> Double
floatMod x y =
  let m = c_fmod x y
  in if m /= 0
       then if (y < 0) /= (m < 0) then m + y else m
       else copySign 0 y

floatFloorDiv :: Double -> Double -> Double
floatFloorDiv x y =
  let m0 = c_fmod x y
      d0 = (x - m0) / y
      d1 = if m0 /= 0 && ((y < 0) /= (m0 < 0)) then d0 - 1 else d0
  in if d1 /= 0
       then let f = fromInteger (floor d1) :: Double
            in if d1 - f > 0.5 then f + 1 else f
       else copySign 0 (x / y)

copySign :: Double -> Double -> Double
copySign mag sgn = if isNegativeZero sgn || sgn < 0 then negate (abs mag) else abs mag

numCompare :: Number -> Number -> Ordering
numCompare (NI x) (NI y) = compare x y
numCompare x y = compare (toDouble x) (toDouble y)

-- | Evaluate a comparison operator.
compareValues :: CmpOp -> Value -> Value -> Either ErrorKind Bool
compareValues op a b
  | isUndefined a || isUndefined b = Left ErrUndefined
  | otherwise = case op of
      Eq -> Right (valuesEqual a b)
      Ne -> Right (not (valuesEqual a b))
      Lt -> ordering (== LT)
      Le -> ordering (/= GT)
      Gt -> ordering (== GT)
      Ge -> ordering (/= LT)
      In -> membership
      NotIn -> not <$> membership
  where
    ordering p = case (asNumber a, asNumber b) of
      (Just x, Just y) -> Right (p (numCompare x y))
      _ -> case (a, b) of
        (VStr x, VStr y) -> Right (p (compare x y))
        _ -> Left ErrType
    membership = case b of
      VStr hay -> case a of
        VStr needle -> Right (needle `T.isInfixOf` hay)
        _ -> Left ErrType
      VDict d -> Right (case a of
        VStr k -> Map.member k (dictMap d)
        _ -> False)
      VList xs -> Right (any (valuesEqual a) (toList xs))
      _ -> Left ErrType

-- | The @==@ relation on defined values.
valuesEqual :: Value -> Value -> Bool
valuesEqual a b = case (asNumber a, asNumber b) of
  (Just x, Just y) -> numCompare x y == EQ
  _ -> case (a, b) of
    (VStr x, VStr y) -> x == y
    (VNone, VNone) -> True
    (VList x, VList y) -> Seq.length x == Seq.length y && and (zipWith valuesEqual (toList x) (toList y))
    (VDict x, VDict y) ->
      dictSize x == dictSize y
        && all (\(k, v) -> maybe False (valuesEqual v) (dictLookup k y)) (dictToList x)
    _ -> False
