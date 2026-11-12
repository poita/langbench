-- | KBL runtime values and their total order.
module Kiln.Value
  ( Value (..)
  , typeName
  , renderScalar
  ) where

import qualified Data.ByteString as B
import Data.Sequence (Seq)

import Kiln.Text (renderInt)

-- | A KBL value. The derived 'Ord' is exactly the language's total order:
-- @bool < int < str < list@, then within a type by value (strings by
-- unsigned byte comparison, lists element by element).
data Value
  = VBool !Bool
  | VInt !Int
  | VStr !B.ByteString
  | VList !(Seq Value)
  deriving (Eq, Ord, Show)

-- | The type token used in error messages.
typeName :: Value -> B.ByteString
typeName v = case v of
  VBool _ -> "bool"
  VInt _ -> "int"
  VStr _ -> "str"
  VList _ -> "list"

-- | The text of a scalar as interpolation and @str()@ produce it.
renderScalar :: Value -> Maybe B.ByteString
renderScalar v = case v of
  VStr s -> Just s
  VInt n -> Just (renderInt n)
  VBool b -> Just (if b then "true" else "false")
  VList _ -> Nothing
