-- | A small jq-subset interpreter.
--
-- > import Jq
-- > import qualified Data.Text as T
-- >
-- > main :: IO ()
-- > main = do
-- >   let Right prog = parseFilter (T.pack ".users | map(.age) | add")
-- >       Right doc  = parseJSON (BC.pack "{\"users\":[{\"age\":3},{\"age\":4}]}")
-- >   mapM_ (BLC.putStrLn . renderValue) (fst (results prog doc))   -- 7
--
-- The pipeline is: 'parseFilter' (filter text to 'Expr'), 'parseJSON'
-- (document to 'Value'), 'evalTop' (lazy 'Stream' of outputs), 'encodeValue'
-- (compact JSON).
module Jq
  ( -- * Values
    Value (..)
  , Object
  , objectFromList
  , objectToList
  , objectLookup
  , compareValues
    -- * JSON
  , parseJSON
  , encodeValue
  , renderValue
    -- * Filters
  , Expr
  , parseFilter
    -- * Evaluation
  , Stream (..)
  , evalTop
  , results
  , runFilter
    -- * The command-line contract
  , processInput
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import Data.ByteString (ByteString)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import Data.Text (Text)

import Jq.Eval
import Jq.Json.Encoder
import Jq.Json.Parser
import Jq.Parser
import Jq.Stream
import Jq.Syntax (Expr)
import Jq.Value

-- | Parse a JSON document (UTF-8). See "Jq.Json.Parser".
parseJSON :: ByteString -> Either String Value
parseJSON = parseJson

-- | Evaluate a filter, returning the outputs produced and, if evaluation
-- aborted, the error message that ended it.
results :: Expr -> Value -> ([Value], Maybe Text)
results e v = toResults (evalTop e v)

-- | Parse and run a filter over a parsed document, as a list of outputs or
-- the first error (outputs before the error are dropped; use 'results' to
-- keep them).
runFilter :: Text -> Value -> Either String [Value]
runFilter src doc = do
  e <- parseFilter src
  case results e doc of
    (vs, Nothing) -> Right vs
    (_, Just m) -> Left (T.unpack m)

-- | Implement the program contract: the first line of the input is the
-- filter, the rest is one JSON document. Output is one compact JSON line per
-- result; an uncaught error ends the output with a line @error@.
processInput :: ByteString -> Either String BB.Builder
processInput input = do
  let (line, rest) = B.break (== 10) input
      filterText = TE.decodeUtf8With TE.lenientDecode line
  prog <- parseFilter filterText
  doc <- parseJSON rest
  Right (render (evalTop prog doc))
  where
    render Nil = mempty
    render (Err _) = BB.string7 "error\n"
    render (Cons x s) = encodeValue x <> BB.char7 '\n' <> render s
