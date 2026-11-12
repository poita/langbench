-- | The abstract syntax tree of filters.
module Jq.Syntax
  ( Expr (..)
  , BinOp (..)
  , Builtin0 (..)
  , Builtin1 (..)
  ) where

import Jq.Value (Value)

-- | Binary operators: arithmetic and comparison.
data BinOp = Add | Sub | Mul | Div | Mod | Eq | Ne | Lt | Le | Gt | Ge
  deriving (Eq, Show)

-- | Builtins that take no filter arguments (they act on their input).
data Builtin0
  = Empty | Error | Not | Length | Keys | Type | AddAll | Reverse
  | Sort | Unique | Min | Max | ToString | ToNumber
  deriving (Eq, Show)

-- | Builtins that take one filter argument.
data Builtin1 = Select | Map | SortBy | GroupBy | Has | ErrorWith
  deriving (Eq, Show)

-- | A filter.
data Expr
  = Identity
  | Literal Value
  | Variable String
  | Pipe Expr Expr
  | Comma Expr Expr
  | Negate Expr
  | Binary BinOp Expr Expr
  | And Expr Expr
  | Or Expr Expr
  | ArrayOf (Maybe Expr)
  | ObjectOf [(Expr, Expr)] -- ^ (key expression, value expression)
  | If Expr Expr Expr
  | Bind Expr String Expr -- ^ @source as $name | body@
  | Reduce Expr String Expr Expr -- ^ @reduce source as $name (init; update)@
  | Index Expr Expr Bool -- ^ @target[key]@; the flag marks a tolerant @?@
  | Iterate Expr Bool -- ^ @target[]@
  | Slice Expr (Maybe Expr) (Maybe Expr) Bool -- ^ @target[lo:hi]@
  | Try Expr
  | Call0 Builtin0
  | Call1 Builtin1 Expr
  deriving (Show)
