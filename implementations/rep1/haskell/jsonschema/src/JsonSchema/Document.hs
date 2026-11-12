{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : JsonSchema.Document
-- Description : The request\/response document of the command-line tool.
--
-- A request is one JSON object with a @schema@, an optional @remotes@ object
-- (absolute URI to schema document) and a @tests@ array whose elements have a
-- @data@ member.  The response is one @valid@ or @invalid@ line per test.
module JsonSchema.Document
  ( Request (..)
  , decodeRequest
  , runRequest
  , renderVerdicts
  , processBytes
  ) where

import qualified Data.ByteString as B
import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as T

import JsonSchema.Json
import JsonSchema.Schema (compileSchema)
import JsonSchema.Validate (validate)

-- | A decoded request.
data Request = Request
  { reqSchema :: Value
  , reqRemotes :: [(Text, Value)]
  , reqInstances :: [Value]
  } deriving (Show)

-- | Decode the top-level document into a 'Request'.
decodeRequest :: Value -> Either String Request
decodeRequest (Obj m) = do
  schema <- maybe (Left "missing \"schema\"") Right (M.lookup "schema" m)
  tests <- case M.lookup "tests" m of
    Just (Arr ts) -> Right ts
    _ -> Left "\"tests\" must be an array"
  instances <- mapM testData tests
  let remotes = case M.lookup "remotes" m of
        Just (Obj r) -> M.toList r
        _ -> []
  Right (Request schema remotes instances)
  where
    testData (Obj t) = maybe (Left "test without \"data\"") Right (M.lookup "data" t)
    testData _ = Left "each test must be an object"
decodeRequest _ = Left "the document must be a JSON object"

-- | Validate every instance of a request.
runRequest :: Request -> [Bool]
runRequest (Request schema remotes instances) = map (validate compiled) instances
  where
    compiled = compileSchema schema remotes

-- | One line per verdict, each terminated by a newline.
renderVerdicts :: [Bool] -> Text
renderVerdicts = T.concat . map (\b -> if b then "valid\n" else "invalid\n")

-- | The whole contract: UTF-8 request bytes in, response text out.
processBytes :: B.ByteString -> Either String Text
processBytes bytes = case parseJsonBytes bytes of
  Left (ParseError off msg) -> Left ("invalid JSON at offset " ++ show off ++ ": " ++ msg)
  Right v -> renderVerdicts . runRequest <$> decodeRequest v
