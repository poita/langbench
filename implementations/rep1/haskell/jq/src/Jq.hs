-- | A jq-subset query language.
--
-- > import qualified Data.Text as T
-- > import Jq
-- >
-- > main :: IO ()
-- > main = case query (T.pack ".a | map(. * 2)") (T.pack "{\"a\":[1,2,3]}") of
-- >   Left err -> putStrLn err
-- >   Right outs -> mapM_ (either (const (putStrLn "error")) (print . renderText)) outs
module Jq
  ( -- * Running filters
    query
  , runFilter
  , EvalError (..)
    -- * Parsing and rendering
  , Expr
  , parseFilter
  , parseJson
  , renderValue
  , renderText
  , renderStrict
    -- * Values
  , Value (..)
  , Object
  , objFromList
  , objToList
  ) where

import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Jq.Eval (evalStream)
import Jq.Json.Parse (parseJson)
import Jq.Json.Render (renderStrict, renderText, renderValue)
import Jq.Parser (parseFilter)
import Jq.Stream (toEithers)
import Jq.Syntax (Expr)
import Jq.Value

-- | A runtime error raised by a filter (jq error messages are not modelled).
data EvalError = EvalError
  deriving (Eq, Show)

-- | Run a parsed filter on a value.  The result is lazy: every output
-- produced before an error is available, and an error appears as a single
-- final 'Left'.
runFilter :: Expr -> Value -> [Either EvalError Value]
runFilter e = toEithers EvalError . evalStream e

-- | Parse a filter and a JSON document and run one on the other.
-- 'Left' reports a filter or document syntax error.
query :: T.Text -> T.Text -> Either String [Either EvalError Value]
query filt doc = do
  f <- parseFilter filt
  v <- parseJson (TE.encodeUtf8 doc)
  Right (runFilter f v)
