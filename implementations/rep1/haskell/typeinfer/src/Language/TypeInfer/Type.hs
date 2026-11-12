-- | Plain, immutable types: the result of inference, and the input for
-- defining built-ins. Also the pretty-printer that implements the output
-- format of the command-line tool.
module Language.TypeInfer.Type
  ( Type (..)
  , renderType
  , varName
  , freeVars
  ) where

import Data.Char (chr, ord)
import Data.List (intersperse, nub)

-- | Monotypes. Type variables are identified by an 'Int'; types returned by
-- the inference functions number their variables @0, 1, 2, ...@ in order of
-- first appearance when read left to right.
data Type
  = TInt
  | TBool
  | TUnit
  | TVar !Int
  | TFun Type Type
  | TTuple [Type]
    -- ^ A tuple of two or more components.
  | TList Type
  deriving (Eq, Ord, Show)

-- | The name of the type variable with the given number: @'a@ .. @'z@, then
-- @'a1@ .. @'z1@, @'a2@, and so on.
varName :: Int -> String
varName i = '\'' : chr (ord 'a' + i `mod` 26) : suffix
  where
    suffix = case i `div` 26 of
      0 -> ""
      k -> show k

-- | Render a type as in the CLI output: @->@ is right-associative, function
-- and tuple types are parenthesised only where necessary, @list@ is postfix.
--
-- >>> renderType (TFun (TFun (TVar 0) (TVar 1)) (TList (TVar 1)))
-- "('a -> 'b) -> 'b list"
renderType :: Type -> String
renderType t = go Top t ""
  where
    go :: Ctx -> Type -> ShowS
    go c = \case
      TInt -> showString "int"
      TBool -> showString "bool"
      TUnit -> showString "unit"
      TVar i -> showString (varName i)
      TFun a b -> paren (c >= LeftOfArrow) (go LeftOfArrow a . showString " -> " . go Top b)
      TTuple ts ->
        paren (c >= Component)
          (foldr (.) id (intersperse (showString " * ") (map (go Component) ts)))
      TList e -> go Component e . showString " list"
    paren b s = if b then showChar '(' . s . showChar ')' else s

-- | Where a type is being printed; later constructors need more parentheses.
data Ctx = Top | LeftOfArrow | Component
  deriving (Eq, Ord)

-- | The distinct type variables of a type, in order of first appearance.
freeVars :: Type -> [Int]
freeVars = nub . go
  where
    go = \case
      TVar i -> [i]
      TFun a b -> go a ++ go b
      TTuple ts -> concatMap go ts
      TList e -> go e
      _ -> []
