-- | The abstract syntax of KBL build files.
module Kiln.Syntax
  ( Expr (..)
  , StrPart (..)
  , UnaryOp (..)
  , BinOp (..)
  , binOpText
  , Stmt (..)
  , Arg (..)
  , Param (..)
  , StepField (..)
  ) where

import qualified Data.ByteString as BS
import Data.Int (Int64)

data Expr
  = EInt !Int64
  | EBool !Bool
  | EStr !BS.ByteString
  | EInterp [StrPart]
  | EVar !BS.ByteString
  | EList [Expr]
  | EUnary !UnaryOp Expr
  | EBinary !BinOp Expr Expr
  | ECall !BS.ByteString [Expr]
  | EIndex Expr Expr
  deriving (Eq, Show)

-- | A piece of a double-quoted literal.
data StrPart = PLit !BS.ByteString | PHole Expr
  deriving (Eq, Show)

data UnaryOp = Not | Neg
  deriving (Eq, Show)

data BinOp
  = Or | And | Eq | Ne | Lt | Le | Gt | Ge
  | ConcatList | ConcatStr | Add | Sub | Mul | Div | Mod
  deriving (Eq, Show)

-- | The operator's source spelling (used in type-error sites).
binOpText :: BinOp -> BS.ByteString
binOpText op = case op of
  Or -> "||"
  And -> "&&"
  Eq -> "=="
  Ne -> "!="
  Lt -> "<"
  Le -> "<="
  Gt -> ">"
  Ge -> ">="
  ConcatList -> "++"
  ConcatStr -> "~"
  Add -> "+"
  Sub -> "-"
  Mul -> "*"
  Div -> "/"
  Mod -> "%"

data Arg = Pos Expr | Kw !BS.ByteString Expr
  deriving (Eq, Show)

data Param = Param !BS.ByteString (Maybe Expr)
  deriving (Eq, Show)

data StepField
  = FOut Expr
  | FIn Expr
  | FAfter Expr
  | FCost Expr
  | FDepfile Expr
  | FCmd !BS.ByteString [Expr]
  deriving (Eq, Show)

data Stmt
  = SLet !BS.ByteString Expr
  | SSet !BS.ByteString Expr
  | SInclude Expr
  | SAbort Expr
  | SDefault Expr
  | SPhony !BS.ByteString Expr
  | SUse !BS.ByteString [Arg]
  | SWhen [(Expr, [Stmt])] (Maybe [Stmt])
  | SEach (Maybe BS.ByteString) !BS.ByteString Expr [Stmt]
  | SRule !BS.ByteString [Param] [Stmt]
  | SStep [StepField]
  deriving (Eq, Show)
