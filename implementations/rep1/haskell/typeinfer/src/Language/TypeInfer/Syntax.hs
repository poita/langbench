-- | Abstract syntax of the source language, plus a printer that produces
-- source text the parser accepts back.
module Language.TypeInfer.Syntax
  ( Name
  , Lit (..)
  , BinOp (..)
  , Expr (..)
  , Decl (..)
  , Program
  , declName
  , mkFuns
  , binOpSymbol
  , renderExpr
  , renderDecl
  ) where

import Data.List (intersperse)

-- | Identifiers.
type Name = String

-- | Literals. The value of an integer literal is irrelevant to typing, so
-- only its digits are kept (they may be arbitrarily long).
data Lit
  = LInt String
  | LBool Bool
  | LUnit
  deriving (Eq, Show)

-- | Binary operators other than @::@.
data BinOp
  = Add | Sub | Mul | Div   -- ^ @int -> int -> int@
  | Eq | Lt | Gt | Le | Ge  -- ^ @int -> int -> bool@
  | And | Or                -- ^ @bool -> bool -> bool@
  deriving (Eq, Show, Enum, Bounded)

-- | Expressions. Multi-parameter @fun@s and @let f x y = ...@ are desugared by
-- the parser into nested single-parameter 'EFun's.
data Expr
  = EVar Name
  | ELit Lit
  | EApp Expr Expr
  | EFun Name Expr
  | ELet Name Expr Expr
    -- ^ @let x = e1 in e2@ (the name is not in scope in @e1@).
  | ELetRec Name Name Expr Expr
    -- ^ @ELetRec f x e1 e2@ is @let rec f x = e1 in e2@: @f@ is bound to
    -- @fun x -> e1@, recursively, in @e2@.
  | EIf Expr Expr Expr
  | ETuple [Expr]
    -- ^ At least two components.
  | EList [Expr]
  | ECons Expr Expr
  | EBin BinOp Expr Expr
  deriving (Eq, Show)

-- | A top-level declaration.
data Decl
  = DLet Name Expr
    -- ^ @let x = e;;@
  | DLetRec Name Name Expr
    -- ^ @DLetRec f x e@ is @let rec f x = e;;@.
  | DExpr Expr
    -- ^ A bare expression @e;;@.
  deriving (Eq, Show)

-- | A program is a sequence of declarations.
type Program = [Decl]

-- | The name a declaration binds, if any.
declName :: Decl -> Maybe Name
declName = \case
  DLet n _      -> Just n
  DLetRec n _ _ -> Just n
  DExpr _       -> Nothing

-- | @mkFuns [x, y] e@ is @fun x -> fun y -> e@.
mkFuns :: [Name] -> Expr -> Expr
mkFuns ps body = foldr EFun body ps

-- | Concrete syntax of a binary operator.
binOpSymbol :: BinOp -> String
binOpSymbol = \case
  Add -> "+"; Sub -> "-"; Mul -> "*"; Div -> "/"
  Eq -> "="; Lt -> "<"; Gt -> ">"; Le -> "<="; Ge -> ">="
  And -> "&&"; Or -> "||"

-- | Render an expression as fully parenthesised source text. Parsing the
-- result yields the original expression.
renderExpr :: Expr -> String
renderExpr e = expr e ""

expr :: Expr -> ShowS
expr = \case
  EVar x -> showString x
  ELit (LInt ds) -> showString ds
  ELit (LBool b) -> showString (if b then "true" else "false")
  ELit LUnit -> showString "()"
  EApp f a -> paren (expr f . showChar ' ' . expr a)
  EFun x b -> paren (showString "fun " . showString x . showString " -> " . expr b)
  ELet x a b ->
    paren (showString "let " . showString x . showString " = " . expr a
           . showString " in " . expr b)
  ELetRec f x a b ->
    paren (showString "let rec " . showString f . showChar ' ' . showString x
           . showString " = " . expr a . showString " in " . expr b)
  EIf c a b ->
    paren (showString "if " . expr c . showString " then " . expr a
           . showString " else " . expr b)
  ETuple es -> paren (commaSep ", " es)
  EList es -> showChar '[' . commaSep "; " es . showChar ']'
  ECons a b -> paren (expr a . showString " :: " . expr b)
  EBin op a b -> paren (expr a . showChar ' ' . showString (binOpSymbol op) . showChar ' ' . expr b)
  where
    paren s = showChar '(' . s . showChar ')'
    commaSep sep = foldr (.) id . intersperse (showString sep) . map expr

-- | Render a declaration, including the terminating @;;@.
renderDecl :: Decl -> String
renderDecl d = case d of
  DLet n e -> "let " ++ n ++ " = " ++ renderExpr e ++ ";;"
  DLetRec f x e -> "let rec " ++ f ++ " " ++ x ++ " = " ++ renderExpr e ++ ";;"
  DExpr e -> renderExpr e ++ ";;"
