-- | The abstract syntax tree produced by "MiniSQL.Parser".
--
-- All identifiers are stored lower-cased, because the language is
-- case-insensitive.
module MiniSQL.Syntax
  ( Statement (..)
  , ColumnType (..)
  , Select (..)
  , SelectItem (..)
  , TableRef (..)
  , ColumnRef (..)
  , OrderTerm (..)
  , OrderKey (..)
  , Expr (..)
  , ArithOp (..)
  , CmpOp (..)
  , AggFn (..)
  , hasAggregate
  ) where

import Data.Text (Text)

-- | A parsed statement.
data Statement
  = CreateTable Text [(Text, ColumnType)]
  | Insert Text [[Expr]]
  | Delete Text (Maybe Expr)
  | Update Text [(Text, Expr)] (Maybe Expr)
  | SelectStmt Select
  deriving (Eq, Show)

-- | Declared column types (informational only).
data ColumnType = TypeInteger | TypeText
  deriving (Eq, Show)

-- | A @SELECT@ statement.
data Select = Select
  { selItems :: [SelectItem]
  , selFrom :: [TableRef]
  -- ^ Zero, one or two tables.
  , selJoinOn :: Maybe Expr
  -- ^ The @ON@ expression of an @INNER JOIN@.
  , selWhere :: Maybe Expr
  , selGroupBy :: [ColumnRef]
  , selHaving :: Maybe Expr
  , selOrderBy :: [OrderTerm]
  , selLimit :: Maybe Int
  , selOffset :: Maybe Int
  }
  deriving (Eq, Show)

-- | One entry of the select list.
data SelectItem
  = Star
  | Item Expr (Maybe Text)
  -- ^ An expression with its optional alias.
  deriving (Eq, Show)

-- | A table in the @FROM@ clause with its optional alias.
data TableRef = TableRef
  { trName :: Text
  , trAlias :: Maybe Text
  }
  deriving (Eq, Show)

-- | A possibly qualified column reference.
data ColumnRef = ColumnRef (Maybe Text) Text
  deriving (Eq, Show)

-- | An @ORDER BY@ term; the flag is 'True' for @DESC@.
data OrderTerm = OrderTerm OrderKey Bool
  deriving (Eq, Show)

-- | What an @ORDER BY@ term sorts on, as far as the parser can tell.
data OrderKey
  = OrdOrdinal Int
  -- ^ A bare integer literal: an output column position.
  | OrdName Text
  -- ^ A bare identifier: an item alias if one matches, else a column.
  | OrdExpr Expr
  deriving (Eq, Show)

-- | Arithmetic operators.
data ArithOp = Add | Sub | Mul | Div | Mod
  deriving (Eq, Show)

-- | Comparison operators.
data CmpOp = Eq | Ne | Lt | Le | Gt | Ge
  deriving (Eq, Show)

-- | Aggregate functions.
data AggFn = Count | Sum | Min | Max | Avg
  deriving (Eq, Show)

-- | An expression.
data Expr
  = EInt Int
  | EStr Text
  | ENull
  | ECol (Maybe Text) Text
  | ENeg Expr
  | EArith ArithOp Expr Expr
  | ECmp CmpOp Expr Expr
  | EAnd Expr Expr
  | EOr Expr Expr
  | ENot Expr
  | EIsNull Expr
  | ELike Expr Expr
  | EAgg AggFn (Maybe Expr)
  -- ^ The argument is 'Nothing' only for @COUNT(*)@.
  deriving (Eq, Show)

-- | Does the expression contain an aggregate call?
hasAggregate :: Expr -> Bool
hasAggregate e = case e of
  EAgg _ _ -> True
  ENeg a -> hasAggregate a
  EArith _ a b -> hasAggregate a || hasAggregate b
  ECmp _ a b -> hasAggregate a || hasAggregate b
  EAnd a b -> hasAggregate a || hasAggregate b
  EOr a b -> hasAggregate a || hasAggregate b
  ENot a -> hasAggregate a
  EIsNull a -> hasAggregate a
  ELike a b -> hasAggregate a || hasAggregate b
  EInt _ -> False
  EStr _ -> False
  ENull -> False
  ECol _ _ -> False
