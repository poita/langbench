-- |
-- Module      : Git.Query
-- Description : The six queries: log, ls-tree, cat-file, diff, rev-parse, count-objects.
--
-- Each query returns the exact bytes of its answer and throws 'GitError'
-- when it fails.
module Git.Query
  ( logHistory
  , lsTree
  , catFile
  , diffTrees
  , revParse
  , countObjects
  ) where

import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Numeric (showOct)

import Git.Object
import Git.Quote (quotePath)
import Git.Revision
import Git.SHA1 (sha1)
import Git.Store
import Git.Types

build :: B.Builder -> BS.ByteString
build = BL.toStrict . B.toLazyByteString

hex :: ObjectId -> B.Builder
hex = B.byteString . objectIdToHex

mode6 :: Int -> B.Builder
mode6 m = let s = showOct m "" in B.string7 (replicate (6 - length s) '0' ++ s)

-- | @rev-parse@: the id a revision resolves to, with a newline.
revParse :: Repository -> BS.ByteString -> IO BS.ByteString
revParse repo rev = do
  oid <- resolveRevision repo rev
  pure (build (hex oid <> B.char7 '\n'))

-- | @cat-file@: @\<type\> \<size\>\\n@ and the payload, after verifying that
-- the SHA-1 of the stored form is the object's id.
catFile :: Repository -> BS.ByteString -> IO BS.ByteString
catFile repo rev = do
  oid <- resolveRevision repo rev
  o <- readObject repo oid
  let form = storedForm o
  if sha1 form /= objectIdBytes oid
    then failWith (DamagedObject "object does not match its id")
    else
      pure . build $
        B.byteString (objectTypeName (objectType o)) <> B.char7 ' '
          <> B.intDec (BS.length (objectPayload o)) <> B.char7 '\n'
          <> B.byteString (objectPayload o)

-- | @count-objects@.
countObjects :: Repository -> BS.ByteString
countObjects repo =
  let c = repoCounts repo
   in build . mconcat $
        [ B.string7 "loose: " <> B.intDec (countLoose c) <> B.char7 '\n'
        , B.string7 "in-pack: " <> B.intDec (countInPack c) <> B.char7 '\n'
        , B.string7 "packs: " <> B.intDec (countPacks c) <> B.char7 '\n'
        ]

-- | @ls-tree \<rev\> [\<path\>]@.
lsTree :: Repository -> BS.ByteString -> Maybe BS.ByteString -> IO BS.ByteString
lsTree repo rev mpath = do
  comps <- case mpath of
    Nothing -> pure []
    Just p
      | BS.null p || any (\c -> BS.null c || c == BC.pack "." || c == BC.pack "..") parts -> failWith (BadCommand "bad path")
      | otherwise -> pure parts
      where
        parts = BS.split 47 p
  root <- resolveRevision repo rev >>= peelToTree repo
  tree <- walk root comps
  entries <- readTree repo tree
  pure . build . mconcat $
    [ mode6 (entryMode e) <> B.char7 ' ' <> B.byteString (objectTypeName (entryType e)) <> B.char7 ' '
        <> hex (entryId e) <> B.char7 '\t' <> B.byteString (quotePath (entryName e)) <> B.char7 '\n'
    | e <- entries
    ]
  where
    walk oid [] = pure oid
    walk oid (c : cs) = do
      entries <- readTree repo oid
      case [entryId e | e <- entries, entryName e == c, entryType e == TTree] of
        (next : _) -> walk next cs
        [] -> failWith (BadCommand "no such tree entry")

-- | @diff \<rev1\> \<rev2\>@: the raw per-file differences of two trees.
diffTrees :: Repository -> BS.ByteString -> BS.ByteString -> IO BS.ByteString
diffTrees repo rev1 rev2 = do
  t1 <- resolveRevision repo rev1 >>= peelToTree repo
  t2 <- resolveRevision repo rev2 >>= peelToTree repo
  m1 <- flatten t1
  m2 <- flatten t2
  let paths = Set.toAscList (Map.keysSet m1 `Set.union` Map.keysSet m2)
      line path = case (Map.lookup path m1, Map.lookup path m2) of
        (a, b) | a == b -> mempty
        (Nothing, Just (m, i)) -> row path (0, zeroObjectId) (m, i) 'A'
        (Just (m, i), Nothing) -> row path (m, i) (0, zeroObjectId) 'D'
        (Just x@(ma, _), Just y@(mb, _)) -> row path x y (if ma .&. 0o170000 == mb .&. 0o170000 then 'M' else 'T')
        (Nothing, Nothing) -> mempty
      row path (ma, ia) (mb, ib) st =
        B.char7 ':' <> mode6 ma <> B.char7 ' ' <> mode6 mb <> B.char7 ' ' <> hex ia <> B.char7 ' ' <> hex ib
          <> B.char7 ' ' <> B.char7 st <> B.char7 '\t' <> B.byteString (quotePath path) <> B.char7 '\n'
  pure (build (foldMap line paths))
  where
    flatten root = Map.fromList <$> go BS.empty root
    go prefix oid = do
      entries <- readTree repo oid
      concat <$> mapM (entry prefix) entries
    entry prefix e
      | entryType e == TTree = go (prefix <> entryName e <> BC.pack "/") (entryId e)
      | otherwise = pure [(prefix <> entryName e, (entryMode e, entryId e))]

-- | @log \<rev\> [\<n\>]@: history in reverse committer-date order (ties go
-- to the commit discovered first), one line per commit.
logHistory :: Repository -> BS.ByteString -> Maybe Integer -> IO BS.ByteString
logHistory repo rev limit = do
  start <- resolveRevision repo rev >>= peelToCommit repo
  startCommit <- readCommit repo start
  let key c order = (negate (identTimestamp (commitCommitter c)), order :: Int)
      loop _ _ _ 0 acc = pure acc
      loop queue seen next remaining acc = case Map.minViewWithKey queue of
        Nothing -> pure acc
        Just ((_, (oid, c)), queue') -> do
          let line =
                hex oid <> B.char7 ' ' <> B.byteString (identName (commitAuthor c)) <> B.char7 ' '
                  <> B.integerDec (identTimestamp (commitAuthor c)) <> B.char7 ' '
                  <> B.byteString (commitSubject c) <> B.char7 '\n'
          (queue'', seen', next') <- expand queue' seen next (commitParents c)
          loop queue'' seen' next' (remaining - 1) (acc <> line)
      expand queue seen next [] = pure (queue, seen, next)
      expand queue seen next (p : ps)
        | p `Set.member` seen = expand queue seen next ps
        | otherwise = do
            pc <- readCommit repo p
            expand (Map.insert (key pc next) (p, pc) queue) (Set.insert p seen) (next + 1) ps
  out <- loop (Map.singleton (key startCommit 0) (start, startCommit)) (Set.singleton start) 1 (maybe (-1) id limit) mempty
  pure (build out)
