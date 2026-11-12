-- | Abstract syntax of the template language.
module Sitegen.Template.Syntax
  ( Expr (..)
  , BinOp (..)
  , CmpOp (..)
  , Node (..)
  , Template (..)
  , ErrorKind (..)
  , errorKindName
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)

-- | An expression.
data Expr
  = EInt Integer
  | EFloat Double
  | EString Text
  | EBool Bool
  | ENone
  | EName Text
  | EList [Expr]
  | ENeg Expr
  | ENot Expr
  | EBin BinOp Expr Expr
  | EAnd Expr Expr
  | EOr Expr Expr
  | ECompare Expr [(CmpOp, Expr)]
  | EFilter Expr Text [Expr]
  | EIsDefined Bool Expr
  -- ^ @x is defined@ (@False@) or @x is not defined@ (@True@).
  | EAttr Expr Text
  | EIndex Expr Expr
  | ECall Expr [Expr] [(Text, Expr)]
  deriving (Eq, Show)

-- | Binary arithmetic operators.
data BinOp = Add | Sub | Concat | Mul | Div | FloorDiv | Mod | Pow
  deriving (Eq, Show)

-- | Comparison operators.
data CmpOp = Eq | Ne | Lt | Le | Gt | Ge | In | NotIn
  deriving (Eq, Show)

-- | A statement or piece of literal text.
data Node
  = NText Text
  | NPrint Expr
  | NIf [(Expr, [Node])] [Node]
  | NFor Text Expr [Node] [Node]
  | NSet Text Expr
  | NMacro Text [(Text, Maybe Expr)] [Node]
  | NInclude Expr
  | NExtends Expr
  | NBlock Text [Node]
  deriving (Eq, Show)

-- | A parsed template: its body and the bodies of all its blocks by name.
data Template = Template
  { tplBody :: [Node]
  , tplBlocks :: Map Text [Node]
  }
  deriving (Eq, Show)

-- | The kinds of failure that loading or rendering a template can produce.
data ErrorKind
  = SyntaxError
  | FilterError
  | UndefinedError
  | TemplateNotFound
  | TypeError
  deriving (Eq, Show)

-- | The short name of an error kind: @syntax@, @filter@, @undefined@,
-- @template@ or @type@.
errorKindName :: ErrorKind -> String
errorKindName k = case k of
  SyntaxError -> "syntax"
  FilterError -> "filter"
  UndefinedError -> "undefined"
  TemplateNotFound -> "template"
  TypeError -> "type"
