-- |
-- Module      : Json.Canon.Types
-- Description : The JSON document tree and parse errors.
module Json.Canon.Types
  ( Value (..)
  , ParseError (..)
  ) where

import Data.Text (Text)

-- | A parsed JSON document.
--
-- The tree is faithful to the input: arrays and objects keep every element
-- and member in input order, duplicate object keys included. Resolving
-- duplicates and ordering keys happens only when rendering
-- ('Json.Canon.Render.render').
data Value
  = Null
  | Bool !Bool
  | Number !Text
    -- ^ Canonical number text (never converted to a floating-point value):
    -- the lexeme as written, except that an exponent is normalised
    -- (lowercase @e@, no @+@, no leading zeros, @-0@ becomes @0@).
  | String !Text
    -- ^ Fully decoded string (escapes and surrogate pairs resolved).
  | Array [Value]
  | Object [(Text, Value)]
    -- ^ Members in input order, duplicates included.
  deriving (Eq, Show)

-- | Why a document was rejected.
data ParseError = ParseError
  { errorOffset :: !Int
    -- ^ Byte offset in the input at which the problem was detected.
  , errorReason :: String
    -- ^ Short human-readable description.
  }
  deriving (Eq, Show)
