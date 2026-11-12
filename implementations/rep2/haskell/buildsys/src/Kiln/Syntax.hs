-- | The abstract syntax of the Kiln Build Language.
module Kiln.Syntax
  ( Expr (..)
  , Part (..)
  , UnOp (..)
  , BinOp (..)
  , binOpSpelling
  , unOpSpelling
  , Stmt (..)
  , Arg (..)
  , Param (..)
  , StepField (..)
  ) where

import qualified Data.ByteString as B

-- | An expression.
data Expr
  = EIntLit !Int
  | EBoolLit !Bool
  | EStrLit !B.ByteString
    -- ^ a literal string with no interpolation
  | EInterpLit [Part]
    -- ^ a double-quoted literal with at least one interpolation
  | EVar !B.ByteString
  | EListLit [Expr]
  | EUnary !UnOp Expr
  | EBinary !BinOp Expr Expr
  | ECall !B.ByteString [Expr]
    -- ^ a call; @a |> f(b)@ is parsed as @f(a, b)@
  | EIndex Expr Expr
  deriving (Eq, Show)

-- | A piece of a double-quoted string literal.
data Part = PLit !B.ByteString | PExpr Expr
  deriving (Eq, Show)

data UnOp = Not | Neg
  deriving (Eq, Show)

data BinOp
  = Or | And | Eq | Ne | Lt | Le | Gt | Ge
  | ListCat | StrCat | Add | Sub | Mul | Div | Mod
  deriving (Eq, Show)

binOpSpelling :: BinOp -> B.ByteString
binOpSpelling o = case o of
  Or -> "||"; And -> "&&"; Eq -> "=="; Ne -> "!="; Lt -> "<"; Le -> "<="
  Gt -> ">"; Ge -> ">="; ListCat -> "++"; StrCat -> "~"; Add -> "+"
  Sub -> "-"; Mul -> "*"; Div -> "/"; Mod -> "%"

unOpSpelling :: UnOp -> B.ByteString
unOpSpelling Not = "!"
unOpSpelling Neg = "-"

-- | An argument of a @use@ statement.
data Arg = Positional Expr | Keyword !B.ByteString Expr
  deriving (Eq, Show)

-- | A rule parameter with an optional default.
data Param = Param !B.ByteString (Maybe Expr)
  deriving (Eq, Show)

-- | A field of a @step@ block.
data StepField
  = FOut Expr
  | FIn Expr
  | FAfter Expr
  | FCost Expr
  | FDepfile Expr
  | FCmd !B.ByteString [Expr]
  deriving (Eq, Show)

-- | A statement.
data Stmt
  = SLet !B.ByteString Expr
  | SSet !B.ByteString Expr
  | SInclude Expr
  | SAbort Expr
  | SDefault Expr
  | SPhony !B.ByteString Expr
  | SUse !B.ByteString [Arg]
  | SWhen [(Expr, [Stmt])] (Maybe [Stmt])
    -- ^ @when@ / @elsewhen@ branches and an optional @otherwise@
  | SEach (Maybe B.ByteString) !B.ByteString Expr [Stmt]
    -- ^ optional index variable, element variable, subject, body
  | SRule !B.ByteString [Param] [Stmt]
  | SStep [StepField]
  deriving (Eq, Show)
