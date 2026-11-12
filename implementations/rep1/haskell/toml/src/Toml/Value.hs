-- | The data model shared by the decoder, the encoder and the JSON layer.
--
-- Scalars are deliberately kept as /text/: a 'VScalar' holds the type tag and
-- the canonical rendering of the value (see "Toml.Decode" for what canonical
-- means for each type).  Nothing is ever converted to a number or a date and
-- back, which keeps round trips exact.
module Toml.Value
  ( Value (..)
  , Table
  , ScalarType (..)
  , scalarTypeName
  , scalarTypeFromName
    -- * Smart constructors
  , vString
  , vInteger
  , vFloat
  , vBool
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T

import Toml.Internal.Float (formatFloat)

-- | The type tag of a scalar, named as in the toml-test tagged JSON format.
data ScalarType
  = TString
  | TInteger
  | TFloat
  | TBool
  | TDateTime       -- ^ date, time and UTC offset
  | TDateTimeLocal  -- ^ date and time, no offset
  | TDateLocal      -- ^ date only
  | TTimeLocal      -- ^ time only
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A TOML table: keys (already unquoted and unescaped) mapped to values.
-- Iteration order is ascending by Unicode code point.
type Table = Map Text Value

-- | A node of a TOML document.
data Value
  = VScalar !ScalarType !Text
    -- ^ A scalar and its canonical text.
  | VArray [Value]
    -- ^ An array.  An array of tables is simply an array of 'VTable's.
  | VTable Table
    -- ^ A table (including inline tables).
  deriving (Eq, Show)

-- | The tag used for a type in tagged JSON (@"string"@, @"datetime-local"@, …).
scalarTypeName :: ScalarType -> Text
scalarTypeName t = case t of
  TString        -> T.pack "string"
  TInteger       -> T.pack "integer"
  TFloat         -> T.pack "float"
  TBool          -> T.pack "bool"
  TDateTime      -> T.pack "datetime"
  TDateTimeLocal -> T.pack "datetime-local"
  TDateLocal     -> T.pack "date-local"
  TTimeLocal     -> T.pack "time-local"

-- | Inverse of 'scalarTypeName'.
scalarTypeFromName :: Text -> Maybe ScalarType
scalarTypeFromName n = lookup n [(scalarTypeName t, t) | t <- [minBound .. maxBound]]

-- | A string value.
vString :: Text -> Value
vString = VScalar TString

-- | An integer value (the caller is responsible for the signed 64-bit range).
vInteger :: Integer -> Value
vInteger = VScalar TInteger . T.pack . show

-- | A float value, in the canonical 17-significant-digit text form.
vFloat :: Double -> Value
vFloat = VScalar TFloat . formatFloat

-- | A boolean value.
vBool :: Bool -> Value
vBool b = VScalar TBool (T.pack (if b then "true" else "false"))
