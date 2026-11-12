{-# LANGUAGE OverloadedStrings #-}

-- | Field paths (SPEC §6.4): resolving, setting and unsetting a path in a value.
module Tessera.Path
  ( Path
  , pathSegments
  , mkPath
  , parsePath
  , pathText
  , resolve
  , setAt
  , unsetAt
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as Map
import Tessera.Constants (maxPath, maxPathSegments)
import Tessera.Error (ErrorKind (..))
import Tessera.Value (Value (..))

-- | A non-empty sequence of field names.
newtype Path = Path {pathSegments :: [BS.ByteString]}
  deriving (Eq, Ord, Show)

-- | Build a path from segments, enforcing the limits of SPEC §6.4
-- (at most 8 segments, text of at most 30 bytes) and that every segment is a
-- @[A-Za-z_][A-Za-z0-9_]*@ word.
mkPath :: [BS.ByteString] -> Either ErrorKind Path
mkPath segs
  | null segs || not (all isWord segs) = Left Syntax
  | length segs > maxPathSegments = Left BadPath
  | BS.length (BS.intercalate "." segs) > maxPath = Left BadPath
  | otherwise = Right (Path segs)
  where
    isWord s = case BC.uncons s of
      Just (c, r) -> start c && BC.all rest r
      Nothing -> False
    start c = c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    rest c = start c || (c >= '0' && c <= '9')

-- | Parse dotted text such as @"addr.city"@.
parsePath :: BS.ByteString -> Either ErrorKind Path
parsePath = mkPath . BC.split '.'

-- | The path text: segments joined by @.@.
pathText :: Path -> BS.ByteString
pathText = BS.intercalate "." . pathSegments

-- | Resolve a path against a value; lists are never traversed.
resolve :: Path -> Value -> Maybe Value
resolve (Path segs) = go segs
  where
    go [] v = Just v
    go (s : ss) (VObject m) = Map.lookup s m >>= go ss
    go _ _ = Nothing

-- | Set the value at a path, creating missing intermediate objects.
-- Fails with 'NotObject' when a traversed value is not an object.
setAt :: Path -> Value -> Value -> Either ErrorKind Value
setAt (Path segs) new = go segs
  where
    go [] _ = Right new
    go (s : ss) (VObject m) = case ss of
      [] -> Right (VObject (Map.insert s new m))
      _ -> do
        child <- go ss (Map.findWithDefault (VObject Map.empty) s m)
        Right (VObject (Map.insert s child m))
    go _ _ = Left NotObject

-- | Remove the field at a path.  'NotObject' when a traversed value is not an
-- object, 'NoField' when an object lacks the field.
unsetAt :: Path -> Value -> Either ErrorKind Value
unsetAt (Path segs) = go segs
  where
    go [] v = Right v
    go (s : ss) (VObject m) = case Map.lookup s m of
      Nothing -> Left NoField
      Just c
        | null ss -> Right (VObject (Map.delete s m))
        | otherwise -> do
            c' <- go ss c
            Right (VObject (Map.insert s c' m))
    go _ _ = Left NotObject
