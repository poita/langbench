{-# LANGUAGE OverloadedStrings #-}

-- | Shared helpers for the test suite.
module Helpers
  ( runText
  , runFull
  , run
  , bs
  , unbs
  , hexBytes
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Tessera.Script (ScriptResult (..), runScript)

bs :: String -> BS.ByteString
bs = BC.pack

unbs :: BS.ByteString -> String
unbs = BC.unpack

-- | Run a script on a fresh database and return @results.txt@.
runText :: String -> IO String
runText cmds = unbs . resultsText <$> runScript Nothing Nothing (bs cmds)

-- | Run a script on a fresh database.
runFull :: String -> IO ScriptResult
runFull cmds = runScript Nothing Nothing (bs cmds)

-- | Run a script against an existing database and log.
run :: Maybe BS.ByteString -> Maybe BS.ByteString -> String -> IO ScriptResult
run tdb twal cmds = runScript tdb twal (bs cmds)

-- | Bytes from a list of values.
hexBytes :: [Int] -> BS.ByteString
hexBytes = BS.pack . map fromIntegral
