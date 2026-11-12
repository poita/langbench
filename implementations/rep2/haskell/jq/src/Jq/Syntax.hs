-- | The abstract syntax of filters.
module Jq.Syntax
  ( Expr (..)
  , BinOp (..)
  ) where

import Data.Text (Text)

import Jq.Value (Value)

-- | Binary operators that evaluate both operands to values.
data BinOp = Add | Sub | Mul | Div | Mod | Eq | Ne | Lt | Le | Gt | Ge
  deriving (Eq, Show)

-- | A filter expression.
data Expr
  = Identity                          -- ^ @.@
  | Literal Value                     -- ^ number, string, @true@, @false@, @null@
  | Var Text                          -- ^ @$name@
  | Index Expr Expr Bool              -- ^ @t[k]@ (also @.foo@); the flag is the tolerant @?@
  | Iterate Expr Bool                 -- ^ @t[]@
  | Slice Expr (Maybe Expr) (Maybe Expr) Bool  -- ^ @t[a:b]@
  | Try Expr                          -- ^ @e?@ after a non-path term
  | Pipe Expr Expr                    -- ^ @a | b@
  | Comma Expr Expr                   -- ^ @a, b@
  | Neg Expr                          -- ^ @-e@
  | Binop BinOp Expr Expr             -- ^ arithmetic and comparison
  | And Expr Expr
  | Or Expr Expr
  | ArrayCons (Maybe Expr)            -- ^ @[e]@
  | ObjectCons [(Expr, Expr)]         -- ^ @{k: v, ...}@ as key/value expression pairs
  | If Expr Expr (Maybe Expr)         -- ^ @if c then a else b end@ (@elif@ nests)
  | Bind Expr Text Expr               -- ^ @e as $x | body@
  | Reduce Expr Text Expr Expr        -- ^ @reduce src as $x (init; update)@
  | Call Text [Expr]                  -- ^ builtin call
  deriving (Show)
