-- | KBL values, their total order and type names.
module Kiln.Value
  ( Value (..)
  , typeName
  , valueText
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Int (Int64)
import Data.Sequence (Seq)

-- | A KBL value.
data Value
  = VStr !BS.ByteString
  | VInt !Int64
  | VBool !Bool
  | VList !(Seq Value)
  deriving (Eq, Show)

rank :: Value -> Int
rank (VBool _) = 0
rank (VInt _) = 1
rank (VStr _) = 2
rank (VList _) = 3

-- | The total order of the specification: @bool < int < str < list@, and
-- within a type the natural order (lists element-wise, then by length).
instance Ord Value where
  compare (VBool a) (VBool b) = compare a b
  compare (VInt a) (VInt b) = compare a b
  compare (VStr a) (VStr b) = compare a b
  compare (VList a) (VList b) = compare a b
  compare a b = compare (rank a) (rank b)

-- | The type token used in error messages.
typeName :: Value -> BS.ByteString
typeName (VStr _) = "str"
typeName (VInt _) = "int"
typeName (VBool _) = "bool"
typeName (VList _) = "list"

-- | Text of a scalar as produced by interpolation; 'Nothing' for lists.
valueText :: Value -> Maybe BS.ByteString
valueText (VStr s) = Just s
valueText (VInt n) = Just (BC.pack (show n))
valueText (VBool b) = Just (if b then "true" else "false")
valueText (VList _) = Nothing
