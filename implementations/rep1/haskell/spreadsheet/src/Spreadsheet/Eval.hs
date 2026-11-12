-- |
-- Module      : Spreadsheet.Eval
-- Description : Pure evaluation of formulas and dependency extraction.
--
-- Evaluation never recurses into other cells: references read the /stored/
-- value of the cell they name through a lookup function.  Keeping the sheet
-- consistent is the job of "Spreadsheet.Sheet".
module Spreadsheet.Eval
  ( Lookup
  , evaluate
  , evalExpr
  , dependencies
  ) where

import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.Text (Text)
import qualified Data.Text as T

import Spreadsheet.Format (renderValue)
import Spreadsheet.Types

-- | Reads the stored value of a cell by its 'refKey'; 'Nothing' if the cell is
-- empty.
type Lookup = Int -> Maybe Value

-- | The result of evaluating an expression: an error, the empty value
-- ('Nothing') or a number or string (never a 'VError').
type Result = Either ErrorCode (Maybe Value)

-- | The cell value of a formula: the evaluation result, with an empty result
-- becoming the number 0.
evaluate :: Lookup -> Expr -> Value
evaluate look e = case evalExpr look e of
  Left c -> VError c
  Right Nothing -> VNumber 0
  Right (Just v) -> v

-- | The keys ('refKey') of every cell the formula depends on: all valid
-- references plus every cell covered by a range.  Both branches of an @IF@
-- count.
dependencies :: Expr -> IntSet
dependencies = go IntSet.empty
  where
    go acc e = case e of
      ERef r -> IntSet.insert (refKey r) acc
      ENeg x -> go acc x
      EBinary _ a b -> go (go acc a) b
      EIf a b c -> go (go (go acc a) b) c
      ECall _ args -> foldl' arg acc args
      _ -> acc
    arg acc (ArgExpr x) = go acc x
    arg acc (ArgRange a b) = IntSet.union acc (IntSet.fromList (rangeKeys a b))

-- | Evaluate an expression left to right; the first problem encountered wins.
-- 'Right' 'Nothing' is the empty value.
evalExpr :: Lookup -> Expr -> Result
evalExpr look = go
  where
    go :: Expr -> Result
    go e = case e of
      ENumber d -> ok (VNumber d)
      EString s -> ok (VText s)
      ERef r -> case look (refKey r) of
        Nothing -> Right Nothing
        Just (VError c) -> Left c
        Just v -> Right (Just v)
      ENeg x -> do
        d <- go x >>= number
        ok (VNumber (negate d))
      EBinary op a b
        | op `elem` [Add, Sub, Mul, Div] -> do
            x <- go a >>= number
            y <- go b >>= number
            arith op x y
        | op == Concat -> do
            x <- go a
            y <- go b
            ok (VText (textForm x <> textForm y))
        | otherwise -> do
            x <- go a
            y <- go b
            compareOp op x y
      EIf c a b -> do
        d <- go c >>= number
        if d /= 0 then go a else go b
      ECall f args -> do
        ns <- collect args
        aggregate f ns
      EInvalidRef -> Left ErrRef

    collect :: [Arg] -> Either ErrorCode [Double]
    collect args = reverse <$> foldlM' step [] args
      where
        step acc (ArgExpr x) = do
          r <- go x
          case r of
            Nothing -> Right acc
            Just (VNumber d) -> Right (d : acc)
            Just _ -> Left ErrValue
        step acc (ArgRange a b) = foldlM' cell acc (rangeKeys a b)
        cell acc k = case look k of
          Just (VError c) -> Left c
          Just (VNumber d) -> Right (d : acc)
          _ -> Right acc

    foldlM' :: (b -> a -> Either ErrorCode b) -> b -> [a] -> Either ErrorCode b
    foldlM' _ acc [] = Right acc
    foldlM' f acc (x : xs) = case f acc x of
      Left c -> Left c
      Right acc' -> acc' `seq` foldlM' f acc' xs

ok :: Value -> Result
ok = Right . Just

-- | Coerce an operand for arithmetic: empty is 0, a string is an error.
number :: Maybe Value -> Either ErrorCode Double
number Nothing = Right 0
number (Just (VNumber d)) = Right d
number (Just (VText _)) = Left ErrValue
number (Just (VError c)) = Left c

-- | Text form used by @&@: strings are themselves, empty is @""@, numbers
-- are displayed.
textForm :: Maybe Value -> Text
textForm Nothing = T.empty
textForm (Just v) = renderValue v

finite :: Double -> Bool
finite d = not (isNaN d || isInfinite d)

arith :: BinOp -> Double -> Double -> Result
arith op x y = case op of
  Add -> checked (x + y)
  Sub -> checked (x - y)
  Mul -> checked (x * y)
  _
    | y == 0 -> Left ErrDivZero
    | otherwise -> checked (x / y)
  where
    checked r
      | finite r = ok (VNumber r)
      | otherwise = Left ErrValue

compareOp :: BinOp -> Maybe Value -> Maybe Value -> Result
compareOp op a b = case (a, b) of
  (Nothing, Nothing) -> numbers (0 :: Double) 0
  (Nothing, Just (VNumber y)) -> numbers 0 y
  (Nothing, Just (VText y)) -> strings T.empty y
  (Just (VNumber x), Nothing) -> numbers x 0
  (Just (VText x), Nothing) -> strings x T.empty
  (Just (VNumber x), Just (VNumber y)) -> numbers x y
  (Just (VText x), Just (VText y)) -> strings x y
  _ -> mixed
  where
    numbers x y = truth (ordering (compare x y))
    -- 'Text' compares by code point (UTF-8 byte order), a prefix first.
    strings x y = truth (ordering (compare x y))
    ordering o = case op of
      Eq -> o == EQ
      Ne -> o /= EQ
      Lt -> o == LT
      Gt -> o == GT
      Le -> o /= GT
      _ -> o /= LT
    truth t = ok (VNumber (if t then 1 else 0))
    mixed = case op of
      Eq -> truth False
      Ne -> truth True
      _ -> Left ErrValue

aggregate :: AggFn -> [Double] -> Result
aggregate f ns = case f of
  Count -> ok (VNumber (fromIntegral (length ns)))
  Sum -> finiteSum
  Min -> ok (VNumber (extreme min))
  Max -> ok (VNumber (extreme max))
  Avg
    | null ns -> Left ErrDivZero
    | otherwise ->
        let s = foldl' (+) 0 ns
         in if finite s then ok (VNumber (s / fromIntegral (length ns))) else Left ErrValue
  where
    finiteSum =
      let s = foldl' (+) 0 ns
       in if finite s then ok (VNumber s) else Left ErrValue
    extreme g = case ns of
      [] -> 0
      x : xs -> foldl' g x xs
