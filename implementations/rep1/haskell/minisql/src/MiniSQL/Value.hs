-- | Runtime values, their total order, and how they are printed.
module MiniSQL.Value
  ( Value (..)
  , Row
  , mkRow
  , emptyRow
  , rowToList
  , compareValues
  , compareRows
  , truth
  , fromBool
  , renderValue
  , formatHundredths
  ) where

import Data.Array (Array, elems, listArray)
import Data.Text (Text)
import qualified Data.Text as T

-- | A dynamically typed SQL value.
data Value
  = VNull
  | VInt !Int
  | VText !Text
  | VReal !Int
  -- ^ A REAL, only ever produced by @AVG@: a fixed-point number stored as a
  -- count of hundredths (@VReal 450@ is @4.50@).
  deriving (Eq, Show)

-- | A table row (or a joined pair of rows): columns indexed from 0.
type Row = Array Int Value

-- | Build a row from its column values.
mkRow :: [Value] -> Row
mkRow vs = listArray (0, length vs - 1) vs

-- | The row with no columns.
emptyRow :: Row
emptyRow = mkRow []

-- | The column values of a row.
rowToList :: Row -> [Value]
rowToList = elems

-- | The total order used for comparisons, sorting, grouping, @MIN@ and @MAX@:
-- NULL is smallest, then numbers (numerically), then text (by code point).
compareValues :: Value -> Value -> Ordering
compareValues VNull VNull = EQ
compareValues VNull _ = LT
compareValues _ VNull = GT
compareValues (VInt a) (VInt b) = compare a b
compareValues (VReal a) (VReal b) = compare a b
compareValues (VInt a) (VReal b) = compare (toInteger a * 100) (toInteger b)
compareValues (VReal a) (VInt b) = compare (toInteger a) (toInteger b * 100)
compareValues (VText a) (VText b) = compare a b
compareValues (VText _) _ = GT
compareValues _ (VText _) = LT

-- | Lexicographic order on lists of values (used for grouping keys).
compareRows :: [Value] -> [Value] -> Ordering
compareRows [] [] = EQ
compareRows [] _ = LT
compareRows _ [] = GT
compareRows (a : as) (b : bs) = compareValues a b <> compareRows as bs

-- | Interpret a value as a boolean: 'Nothing' is unknown (NULL). Zero is
-- false and any other number true. Text is outside the specification; it is
-- treated as false.
truth :: Value -> Maybe Bool
truth VNull = Nothing
truth (VInt n) = Just (n /= 0)
truth (VReal h) = Just (h /= 0)
truth (VText _) = Just False

-- | @1@ or @0@.
fromBool :: Bool -> Value
fromBool b = VInt (if b then 1 else 0)

-- | The text printed for a value in a result row.
renderValue :: Value -> Text
renderValue VNull = T.pack "NULL"
renderValue (VInt n) = T.pack (show n)
renderValue (VText t) = t
renderValue (VReal h) = formatHundredths h

-- | Format a count of hundredths with exactly two decimals.
formatHundredths :: Int -> Text
formatHundredths h =
  T.pack $
    (if h < 0 then "-" else "")
      ++ show (a `div` 100)
      ++ "."
      ++ pad (show (a `mod` 100))
  where
    a = abs h
    pad s = replicate (2 - length s) '0' ++ s
