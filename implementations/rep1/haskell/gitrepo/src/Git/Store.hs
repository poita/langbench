-- |
-- Module      : Git.Store
-- Description : The object database of one repository: loose objects and packs.
--
-- A 'Repository' is opened once; the pack indexes, the packs and the set of
-- loose object ids are read at that point.  Objects are then read by id (a
-- loose copy first, then the packs in file-name order), and every object that
-- is decoded, every delta base included, and every parsed commit, tree and
-- tag is kept for the lifetime of the 'Repository'.
--
-- Functions here throw 'GitError' when an object is missing or damaged.
module Git.Store
  ( Repository
  , repoPath
  , repoPackedRefs
  , openRepository
    -- * Presence and counting
  , objectPresent
  , findByPrefix
  , Counts (..)
  , repoCounts
    -- * Reading objects
  , readObject
  , readCommit
  , readTree
  , readTag
  ) where

import Control.Exception (IOException, try)
import Control.Monad (filterM, forM)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.IntMap.Strict as IM
import Data.IORef
import Data.List (isSuffixOf, nub, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import System.Directory (doesFileExist, listDirectory)
import System.FilePath (dropExtension, (<.>), (</>))

import Git.Delta (applyDelta)
import Git.Inflate (Inflated (..), zlibDecompress)
import Git.Object
import Git.Pack
import Git.Types

data Pack = Pack
  { packIndex :: !PackIndex
  , packBytes :: !BS.ByteString
  , packCache :: !(IORef (IM.IntMap RawObject))
  }

-- | An opened repository.
data Repository = Repository
  { repoPath :: FilePath
    -- ^ the directory holding @HEAD@, @refs/@ and @objects/@
  , repoPackedRefs :: Map.Map BS.ByteString ObjectId
    -- ^ the entries of @packed-refs@
  , repoLoose :: Set.Set ObjectId
  , repoPacks :: [Pack]
  , repoObjects :: IORef (Map.Map ObjectId RawObject)
  , repoCommits :: IORef (Map.Map ObjectId Commit)
  , repoTrees :: IORef (Map.Map ObjectId [TreeEntry])
  }

-- | Open a repository: the contents of a @.git@ directory, or a bare repo.
-- Missing pieces are treated as empty.
openRepository :: FilePath -> IO Repository
openRepository root = do
  loose <- listLoose root
  packs <- loadPacks root
  packed <- readPackedRefs root
  Repository root packed loose packs
    <$> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty

safeList :: FilePath -> IO [FilePath]
safeList dir = either (const []) id <$> (try (listDirectory dir) :: IO (Either IOException [FilePath]))

isLowerHex :: String -> Bool
isLowerHex = all (`elem` "0123456789abcdef")

listLoose :: FilePath -> IO (Set.Set ObjectId)
listLoose root = do
  let objs = root </> "objects"
  dirs <- filter (\d -> length d == 2 && isLowerHex d) <$> safeList objs
  ids <- forM dirs $ \d -> do
    names <- filter (\n -> length n == 38 && isLowerHex n) <$> safeList (objs </> d)
    names' <- filterM (\n -> doesFileExist (objs </> d </> n)) names
    pure [oid | n <- names', Just oid <- [objectIdFromHex (BC.pack (d ++ n))]]
  pure (Set.fromList (concat ids))

loadPacks :: FilePath -> IO [Pack]
loadPacks root = do
  let dir = root </> "objects" </> "pack"
  names <- sort . filter (".idx" `isSuffixOf`) <$> safeList dir
  fmap concat . forM names $ \n -> do
    let base = dropExtension n
    hasPack <- doesFileExist (dir </> base <.> "pack")
    if not hasPack
      then pure []
      else do
        r <- try (do i <- BS.readFile (dir </> n); p <- BS.readFile (dir </> base <.> "pack"); pure (i, p))
        case r :: Either IOException (BS.ByteString, BS.ByteString) of
          Right (i, p) | Right ix <- parseIndex i, checkPackHeader p -> do
            cache <- newIORef IM.empty
            pure [Pack ix p cache]
          _ -> pure []

readPackedRefs :: FilePath -> IO (Map.Map BS.ByteString ObjectId)
readPackedRefs root = do
  r <- try (BS.readFile (root </> "packed-refs"))
  case r :: Either IOException BS.ByteString of
    Left _ -> pure Map.empty
    Right bs -> pure (Map.fromList (concatMap parseLine (BC.split '\n' bs)))
  where
    parseLine l = case BC.uncons l of
      Just (c, _) | c == '#' || c == '^' -> []
      _ -> case objectIdFromHex (BS.take 40 l) of
        Just oid | BS.length l > 41, BC.index l 40 == ' ' -> [(BS.drop 41 l, oid)]
        _ -> []

------------------------------------------------------------------------------
-- Presence

-- | Is there a loose file or a pack index entry for this id?  (The content
-- is not read.)
objectPresent :: Repository -> ObjectId -> Bool
objectPresent repo oid =
  oid `Set.member` repoLoose repo || any (isJust . (`indexLookup` oid) . packIndex) (repoPacks repo)

-- | The distinct objects (at most two are reported) whose id starts with the
-- given hexadecimal prefix of 4 to 40 digits.  Costs O(log N) per pack and
-- for the loose set.
findByPrefix :: Repository -> BS.ByteString -> [ObjectId]
findByPrefix repo hex = case mkHexPrefix hex of
  Just p | BS.length hex >= 4 ->
    let lo = prefixLowId p
        (_, hit, above) = Set.splitMember lo (repoLoose repo)
        loose = take 2 (takeWhile (matchesPrefix p) ([lo | hit] ++ Set.toAscList above))
        packed = concatMap (\k -> indexPrefixMatches 2 (packIndex k) p) (repoPacks repo)
     in take 2 (nub (sort (loose ++ packed)))
  _ -> []

-- | Object counts, as reported by @count-objects@.
data Counts = Counts
  { countLoose :: !Int
    -- ^ loose object files (including ones also present in a pack)
  , countInPack :: !Int
    -- ^ sum of the object counts of all packs
  , countPacks :: !Int
  }
  deriving (Eq, Show)

repoCounts :: Repository -> Counts
repoCounts repo =
  Counts (Set.size (repoLoose repo)) (sum (map (indexCount . packIndex) (repoPacks repo))) (length (repoPacks repo))

------------------------------------------------------------------------------
-- Reading

damaged :: String -> IO a
damaged = failWith . DamagedObject

-- | Read an object by id: loose copy first, then the packs.  Deltas are
-- resolved.  The result is cached.
readObject :: Repository -> ObjectId -> IO RawObject
readObject repo = readObjectAt repo 0

-- Delta chains are cut off at this depth, which also stops cycles.
maxDepth :: Int
maxDepth = 4096

readObjectAt :: Repository -> Int -> ObjectId -> IO RawObject
readObjectAt repo depth oid = do
  hit <- Map.lookup oid <$> readIORef (repoObjects repo)
  case hit of
    Just o -> pure o
    Nothing -> do
      o <-
        if oid `Set.member` repoLoose repo
          then readLoose repo oid
          else case [(k, i) | k <- repoPacks repo, Just i <- [indexLookup (packIndex k) oid]] of
            ((k, i) : _) -> case indexOffsetAt (packIndex k) i of
              Just off -> readPacked repo depth k off
              Nothing -> damaged "bad pack offset"
            [] -> failWith (ObjectNotFound oid)
      modifyIORef' (repoObjects repo) (Map.insert oid o)
      pure o

readLoose :: Repository -> ObjectId -> IO RawObject
readLoose repo oid = do
  let hex = BC.unpack (objectIdToHex oid)
      path = repoPath repo </> "objects" </> take 2 hex </> drop 2 hex
  r <- try (BS.readFile path)
  bytes <- either (\e -> damaged (show (e :: IOException))) pure r
  case zlibDecompress bytes of
    Left e -> damaged (show e)
    Right inflated -> either damaged pure (parseStoredForm (inflatedBytes inflated))

readPacked :: Repository -> Int -> Pack -> Int -> IO RawObject
readPacked repo depth pack off = do
  hit <- IM.lookup off <$> readIORef (packCache pack)
  case hit of
    Just o -> pure o
    Nothing -> do
      if depth > maxDepth then damaged "delta chain too deep" else pure ()
      entry <- either damaged pure (readPackEntry (packBytes pack) off)
      o <- case entry of
        PackObject t payload -> pure (RawObject t payload)
        OfsDelta baseOff delta -> do
          base <- readPacked repo (depth + 1) pack baseOff
          resolve base delta
        RefDelta baseId delta -> do
          base <- readObjectAt repo (depth + 1) baseId
          resolve base delta
      modifyIORef' (packCache pack) (IM.insert off o)
      pure o
  where
    resolve base delta = case applyDelta (objectPayload base) delta of
      Left e -> damaged e
      Right payload -> pure (RawObject (objectType base) payload)

typed :: Repository -> ObjectType -> ObjectId -> IO RawObject
typed repo ty oid = do
  o <- readObject repo oid
  if objectType o == ty
    then pure o
    else damaged ("object " ++ show oid ++ " is a " ++ BC.unpack (objectTypeName (objectType o)) ++ ", not a " ++ BC.unpack (objectTypeName ty))

cached :: Ord k => IORef (Map.Map k v) -> k -> IO v -> IO v
cached ref k compute = do
  m <- readIORef ref
  case Map.lookup k m of
    Just v -> pure v
    Nothing -> do
      v <- compute
      modifyIORef' ref (Map.insert k v)
      pure v

-- | Read and parse a commit (parsed once per run).
readCommit :: Repository -> ObjectId -> IO Commit
readCommit repo oid = cached (repoCommits repo) oid $ do
  o <- typed repo TCommit oid
  either damaged pure (parseCommit (objectPayload o))

-- | Read and parse a tree (parsed once per run).
readTree :: Repository -> ObjectId -> IO [TreeEntry]
readTree repo oid = cached (repoTrees repo) oid $ do
  o <- typed repo TTree oid
  either damaged pure (parseTree (objectPayload o))

-- | Read and parse a tag object.
readTag :: Repository -> ObjectId -> IO Tag
readTag repo oid = do
  o <- typed repo TTag oid
  either damaged pure (parseTag (objectPayload o))
