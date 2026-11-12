-- | The abstract syntax tree of a parsed template.
module Template.Syntax
  ( Expr (..)
  , BinOp (..)
  , CmpOp (..)
  , Param (..)
  , Stmt (..)
  , Template (..)
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)

-- | Binary arithmetic and string operators.
data BinOp = Add | Sub | Concat | Mul | Div | FloorDiv | Mod | Pow
  deriving (Eq, Show)

-- | Comparison operators (these can be chained).
data CmpOp = Eq | Ne | Lt | Le | Gt | Ge | In | NotIn
  deriving (Eq, Show)

-- | Expressions.
data Expr
  = EInt Integer
  | EFloat Double
  | EStr Text
  | EBool Bool
  | ENone
  | EVar Text
  | EList [Expr]
  | EIndex Expr Expr            -- ^ @a.name@ and @a[expr]@
  | ENeg Expr
  | ENot Expr
  | EBin BinOp Expr Expr
  | EAnd Expr Expr
  | EOr Expr Expr
  | ECompare Expr [(CmpOp, Expr)]
  | EFilter Expr Text [Expr]
  | EIsDefined Expr
  | ECall Expr [Expr] [(Text, Expr)]
  deriving (Show)

-- | A macro parameter with an optional default expression.
data Param = Param Text (Maybe Expr)
  deriving (Show)

-- | Statements (the body of a template is a list of them).
data Stmt
  = SText Text
  | SPrint Expr
  | SIf [(Expr, [Stmt])] [Stmt]       -- ^ branches and the else body
  | SFor Text Expr [Stmt] [Stmt]      -- ^ variable, iterable, body, else body
  | SSet Text Expr
  | SMacro Text [Param] [Stmt]
  | SInclude Expr
  | SExtends Expr
  | SBlock Text
  deriving (Show)

-- | A parsed and checked template.
data Template = Template
  { tplBody   :: [Stmt]
  , tplBlocks :: Map Text [Stmt]
    -- ^ the bodies of every @block@ tag in the template, by name
  } deriving (Show)
