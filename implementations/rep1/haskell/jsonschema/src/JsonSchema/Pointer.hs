{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : JsonSchema.Pointer
-- Description : RFC 6901 JSON Pointers.
module JsonSchema.Pointer
  ( parsePointer
  , escapeToken
  , evalPointer
  ) where

import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

import JsonSchema.Json (Value (..))

-- | Split a pointer such as @\/a\/b~1c@ into unescaped reference tokens.
-- The empty pointer is the empty list; a non-empty pointer must start with
-- @\/@ (otherwise 'Nothing').
parsePointer :: Text -> Maybe [Text]
parsePointer p
  | T.null p = Just []
  | Just r <- T.stripPrefix "/" p = Just (map unescape (T.splitOn "/" r))
  | otherwise = Nothing
  where
    unescape = T.replace "~0" "~" . T.replace "~1" "/"

-- | Escape one reference token (@~@ becomes @~0@, @\/@ becomes @~1@).
escapeToken :: Text -> Text
escapeToken = T.replace "/" "~1" . T.replace "~" "~0"

-- | Evaluate a pointer against a JSON value.
evalPointer :: Text -> Value -> Maybe Value
evalPointer p root = parsePointer p >>= go root
  where
    go v [] = Just v
    go (Obj m) (k : ks) = M.lookup k m >>= \x -> go x ks
    go (Arr xs) (k : ks) = do
      i <- readMaybe (T.unpack k) :: Maybe Int
      if i >= 0 && i < length xs && T.all (`elem` ['0' .. '9']) k then go (xs !! i) ks else Nothing
    go _ _ = Nothing
