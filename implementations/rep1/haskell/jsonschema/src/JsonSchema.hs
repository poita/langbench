-- |
-- Module      : JsonSchema
-- Description : A JSON Schema draft 2020-12 validator.
--
-- The public entry point.  Typical use:
--
-- > import JsonSchema
-- >
-- > main :: IO ()
-- > main = do
-- >   let Right schemaDoc = parseJson "{\"type\":\"integer\",\"minimum\":1}"
-- >       schema = compileSchema schemaDoc []
-- >   print (validate schema (Num (mkNumber 3 0)))   -- True
--
-- Numbers are exact decimals, @format@ is annotation-only, and @$ref@
-- targets other than the root document must be supplied up front as
-- /remotes/ (nothing is ever fetched).
module JsonSchema
  ( -- * Compiling and validating
    Schema
  , compileSchema
  , validate
    -- * JSON values
  , Value (..)
  , parseJson
  , parseJsonBytes
  , renderJson
  , ParseError (..)
    -- * Numbers
  , Number
  , mkNumber
    -- * The command-line document format
  , module JsonSchema.Document
  ) where

import JsonSchema.Document
import JsonSchema.Json
import JsonSchema.Number (Number, mkNumber)
import JsonSchema.Schema (Schema, compileSchema)
import JsonSchema.Validate (validate)
