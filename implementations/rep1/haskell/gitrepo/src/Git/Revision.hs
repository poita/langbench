-- |
-- Module      : Git.Revision
-- Description : Resolving revision strings (@main~2^{tree}@, abbreviated ids, ...).
module Git.Revision
  ( resolveRevision
  , Peel (..)
  , peel
  , peelToCommit
  , peelToTree
  ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC

import Git.Object
import Git.Ref (resolveRef)
import Git.Store
import Git.Types

-- | What to peel an object to.
data Peel
  = PeelTags
    -- ^ @^{}@: strip tag layers only
  | PeelTo ObjectType
    -- ^ @^{commit}@ etc.: stop at that type, looking through tags and
    -- (from commits) to trees
  deriving (Eq, Show)

bad :: String -> IO a
bad = failWith . BadRevision

-- | Peel an object as git's @^{...}@ does.  Reads the objects it passes.
peel :: Repository -> Peel -> ObjectId -> IO ObjectId
peel repo how = go
  where
    go oid = do
      o <- readObject repo oid
      let ty = objectType o
      case how of
        PeelTags
          | ty == TTag -> readTag repo oid >>= go . tagTarget
          | otherwise -> pure oid
        PeelTo want
          | ty == want -> pure oid
          | ty == TTag -> readTag repo oid >>= go . tagTarget
          | ty == TCommit -> do
              c <- readCommit repo oid
              maybe (bad "commit without tree") go (commitTree c)
          | otherwise -> bad "cannot peel to the requested type"

-- | @^{commit}@.
peelToCommit :: Repository -> ObjectId -> IO ObjectId
peelToCommit repo = peel repo (PeelTo TCommit)

-- | @^{tree}@.
peelToTree :: Repository -> ObjectId -> IO ObjectId
peelToTree repo = peel repo (PeelTo TTree)

-- | Resolve a revision to an object id, following git's rules: a trailing
-- @^{...}@ peel, then a trailing @^n@ / @~n@, then a ref name tried against
-- six patterns, then a 4–40 digit hexadecimal id or unique abbreviation.
-- Throws 'BadRevision' on failure.
resolveRevision :: Repository -> ByteString -> IO ObjectId
resolveRevision repo rev
  | Just (base, inner) <- splitPeel = do
      oid <- resolveRevision repo base
      case BC.unpack inner of
        "" -> peel repo PeelTags oid
        "commit" -> peel repo (PeelTo TCommit) oid
        "tree" -> peel repo (PeelTo TTree) oid
        "blob" -> peel repo (PeelTo TBlob) oid
        "tag" -> peel repo (PeelTo TTag) oid
        "object" -> do
          when (not (objectPresent repo oid)) $ bad "object not present"
          pure oid
        _ -> bad "unknown peel"
  | Just (base, op, n) <- splitSuffix = do
      oid <- resolveRevision repo base >>= peelToCommit repo
      if n == 0 then pure oid else if op == '^' then nthParent oid n else ancestor oid n
  | otherwise = do
      named <- firstJustM (resolveRef repo) patterns
      case named of
        Just oid -> pure oid
        Nothing -> byHex
  where
    len = BS.length rev

    splitPeel
      | len > 0 && BS.last rev == 125 =
          case [i | i <- [0 .. len - 2], BS.index rev i == 94, BS.index rev (i + 1) == 123] of
            [] -> Nothing
            is | last is == 0 -> Nothing
               | otherwise -> let i = last is in Just (BS.take i rev, BS.take (len - 1 - (i + 2)) (BS.drop (i + 2) rev))
      | otherwise = Nothing

    splitSuffix =
      let digits = BC.takeWhileEnd (\c -> c >= '0' && c <= '9') rev
          opPos = len - BS.length digits - 1
       in if opPos > 0 && (BC.index rev opPos == '^' || BC.index rev opPos == '~')
            then
              Just
                ( BS.take opPos rev
                , BC.index rev opPos
                , if BS.null digits then 1 else BS.foldl' (\a c -> a * 10 + toInteger c - 48) 0 digits :: Integer
                )
            else Nothing

    nthParent oid n = do
      ps <- commitParents <$> readCommit repo oid
      if n > toInteger (length ps) then bad "no such parent" else pure (ps !! fromInteger (n - 1))

    ancestor oid n
      | n == 0 = pure oid
      | otherwise = do
          c <- readCommit repo oid
          case commitParents c of
            (p : _) -> ancestor p (n - 1)
            [] -> bad "no such ancestor"

    name = BC.unpack rev
    patterns =
      map
        BC.pack
        [ name
        , "refs/" ++ name
        , "refs/tags/" ++ name
        , "refs/heads/" ++ name
        , "refs/remotes/" ++ name
        , "refs/remotes/" ++ name ++ "/HEAD"
        ]

    byHex
      | len >= 4 && len <= 40 && BC.all isHex rev =
          case objectIdFromHex (BC.map lower rev <> BC.replicate (40 - len) '0') of
            Just full
              | len == 40 -> if objectPresent repo full then pure full else bad "no such object"
              | otherwise -> case findByPrefix repo rev of
                  [one] -> pure one
                  _ -> bad "unknown or ambiguous abbreviation"
            Nothing -> bad "bad id"
      | otherwise = bad "unknown revision"
    isHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
    lower c = if c >= 'A' && c <= 'F' then toEnum (fromEnum c + 32) else c

firstJustM :: (a -> IO (Maybe b)) -> [a] -> IO (Maybe b)
firstJustM _ [] = pure Nothing
firstJustM f (x : xs) = do
  r <- f x
  case r of
    Just _ -> pure r
    Nothing -> firstJustM f xs
