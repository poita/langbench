{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Spreadsheet.Types
-- Description : Core data types: cell references, values, contents, formulas.
--
-- This module defines the vocabulary shared by every other module in the
-- library.  It contains no evaluation logic.
module Spreadsheet.Types
  ( -- * Cell references
    CellRef
  , mkCellRef
  , refCol
  , refRow
  , maxColumn
  , maxRow
  , showCellRef
    -- ** Integer keys
  , refKey
  , keyRef
  , rangeKeys
    -- * Values
  , ErrorCode (..)
  , errorText
  , Value (..)
    -- * Cell contents and formulas
  , Content (..)
  , Expr (..)
  , BinOp (..)
  , AggFn (..)
  , Arg (..)
  ) where

import Data.Char (chr, ord)
import Data.Text (Text)
import qualified Data.Text as T

-- | The largest column number (@ZZ@).
maxColumn :: Int
maxColumn = 702

-- | The largest row number.
maxRow :: Int
maxRow = 9999

-- | A cell address such as @A1@ or @ZZ9999@.
--
-- Columns are numbered 1..'maxColumn' (@A@..@ZZ@) and rows 1..'maxRow'.
-- Values can only be built with 'mkCellRef', so every 'CellRef' is valid.
-- The 'Ord' instance is row-major: @B1 < A2@.
data CellRef = CellRef !Int !Int
  deriving (Eq)

instance Ord CellRef where
  compare a b = compare (refKey a) (refKey b)

instance Show CellRef where
  show = T.unpack . showCellRef

-- | Build a reference from a 1-based column and row; 'Nothing' if either is
-- out of range.
mkCellRef :: Int -> Int -> Maybe CellRef
mkCellRef c r
  | c >= 1 && c <= maxColumn && r >= 1 && r <= maxRow = Just (CellRef c r)
  | otherwise = Nothing

-- | The 1-based column of a reference.
refCol :: CellRef -> Int
refCol (CellRef c _) = c

-- | The 1-based row of a reference.
refRow :: CellRef -> Int
refRow (CellRef _ r) = r

-- | Render a reference in spreadsheet notation, e.g. @AB12@.
showCellRef :: CellRef -> Text
showCellRef (CellRef c r) = T.pack (colName ++ show r)
  where
    colName
      | c <= 26 = [letter c]
      | otherwise = [letter ((c - 1) `div` 26), letter ((c - 1) `mod` 26 + 1)]
    letter n = chr (ord 'A' + n - 1)

-- Keys are @row * stride + col@, so ascending keys are row-major order.
stride :: Int
stride = 1024

-- | An injective encoding of a reference as an 'Int'.  Ascending keys are in
-- row-major order.  Used as the index of the internal maps.
refKey :: CellRef -> Int
refKey (CellRef c r) = r * stride + c

-- | Inverse of 'refKey'.  The key must have been produced by 'refKey'.
keyRef :: Int -> CellRef
keyRef k = CellRef (k `mod` stride) (k `div` stride)

-- | The keys of every cell in the rectangle spanned by two corners (given in
-- either order), in row-major order.
rangeKeys :: CellRef -> CellRef -> [Int]
rangeKeys (CellRef c1 r1) (CellRef c2 r2) =
  [ r * stride + c | r <- [min r1 r2 .. max r1 r2], c <- [min c1 c2 .. max c1 c2] ]

-- | The four error codes a formula can evaluate to.
data ErrorCode
  = ErrDivZero  -- ^ @#DIV/0!@
  | ErrRef      -- ^ @#REF!@
  | ErrCycle    -- ^ @#CYCLE!@
  | ErrValue    -- ^ @#VALUE!@
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The text of an error code as displayed in a cell.
errorText :: ErrorCode -> Text
errorText ErrDivZero = "#DIV/0!"
errorText ErrRef = "#REF!"
errorText ErrCycle = "#CYCLE!"
errorText ErrValue = "#VALUE!"

-- | The value of a non-empty cell.  Numbers are always finite.
data Value
  = VNumber !Double
  | VText !Text
  | VError !ErrorCode
  deriving (Eq, Show)

-- | What a cell holds.
data Content
  = CNumber !Double   -- ^ a number literal
  | CText !Text       -- ^ a string literal
  | CFormula Expr     -- ^ a parsed formula
  deriving (Eq, Show)

-- | A formula syntax tree with references already resolved.
data Expr
  = ENumber !Double
  | EString !Text
  | ERef !CellRef
  | ENeg Expr
  | EBinary !BinOp Expr Expr
  | EIf Expr Expr Expr
  | ECall !AggFn [Arg]
  | EInvalidRef
    -- ^ The formula mentioned an invalid reference (@AAA1@, @A0@, ...).  The
    -- parser collapses the whole formula to this node; it evaluates to
    -- @#REF!@ and has no dependencies.
  deriving (Eq, Show)

-- | Binary operators.
data BinOp
  = Add | Sub | Mul | Div
  | Concat
  | Eq | Ne | Lt | Gt | Le | Ge
  deriving (Eq, Show, Enum, Bounded)

-- | Aggregate functions.
data AggFn = Sum | Min | Max | Avg | Count
  deriving (Eq, Show, Enum, Bounded)

-- | An argument of an aggregate function.
data Arg
  = ArgExpr Expr
  | ArgRange !CellRef !CellRef  -- ^ @REF:REF@, corners in source order
  deriving (Eq, Show)
