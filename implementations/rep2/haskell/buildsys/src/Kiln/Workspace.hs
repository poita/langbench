-- | The virtual file system a Kiln session runs against.
--
-- A workspace is a flat map from workspace paths to file contents. Every file
-- carries its FNV-1a hash, computed lazily and at most once per stored
-- content, so freshness checks and state lines never rehash an unchanged
-- file.
module Kiln.Workspace
  ( -- * Files
    File
  , mkFile
  , fileContent
  , fileHash
    -- * Workspaces
  , Workspace
  , Path
  , emptyWorkspace
  , fromFiles
  , toFiles
  , lookupFile
  , member
  , insertFile
  , insertContent
  , deleteFile
  , filterPaths
  , paths
    -- * Paths
  , isWorkspacePath
  , firstComponent
  , isGenerated
  , stateFilePath
  , isPhonyShape
  , isIdentShape
    -- * Glob index
  , eligibleWithPrefix
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as M
import Data.Word (Word8)

import Kiln.Hash

-- | A workspace path such as @src/a.txt@.
type Path = B.ByteString

-- | A file's content together with its (lazily computed) hash.
data File = File
  { fileContent :: !B.ByteString
  , fileHash :: Hash
    -- ^ Forced at most once per 'File' value.
  }

-- | Wrap a content. The hash is only computed if somebody asks for it.
mkFile :: B.ByteString -> File
mkFile c = File c (fnv1a c)

-- | A workspace: path to file.
newtype Workspace = Workspace (M.Map Path File)

emptyWorkspace :: Workspace
emptyWorkspace = Workspace M.empty

fromFiles :: [(Path, B.ByteString)] -> Workspace
fromFiles kvs = Workspace (M.fromList [(p, mkFile c) | (p, c) <- kvs])

-- | All files in ascending path order.
toFiles :: Workspace -> [(Path, B.ByteString)]
toFiles (Workspace m) = [(p, fileContent f) | (p, f) <- M.toAscList m]

paths :: Workspace -> [Path]
paths (Workspace m) = M.keys m

lookupFile :: Path -> Workspace -> Maybe File
lookupFile p (Workspace m) = M.lookup p m

member :: Path -> Workspace -> Bool
member p (Workspace m) = M.member p m

insertFile :: Path -> File -> Workspace -> Workspace
insertFile p f (Workspace m) = Workspace (M.insert p f m)

insertContent :: Path -> B.ByteString -> Workspace -> Workspace
insertContent p c = insertFile p (mkFile c)

deleteFile :: Path -> Workspace -> Workspace
deleteFile p (Workspace m) = Workspace (M.delete p m)

-- | Keep the paths satisfying a predicate.
filterPaths :: (Path -> Bool) -> Workspace -> Workspace
filterPaths f (Workspace m) = Workspace (M.filterWithKey (\k _ -> f k) m)

-- | Paths that begin with the given prefix, in ascending order and excluding
-- generated paths (first component @out@) and the state file. Costs
-- O(log F) plus the number of paths sharing the prefix, using the sorted map
-- as the index.
eligibleWithPrefix :: B.ByteString -> Workspace -> [Path]
eligibleWithPrefix prefix (Workspace m) =
  filter eligible . M.keys . M.takeWhileAntitone (B.isPrefixOf prefix)
    $ M.dropWhileAntitone (< prefix) m
  where
    eligible p = not (isGenerated p) && p /= stateFilePath

slash :: Word8
slash = 47

-- | Whether a string is a valid workspace path.
isWorkspacePath :: B.ByteString -> Bool
isWorkspacePath p
  | B.null p || B.length p > 1024 = False
  | otherwise = all okComponent (B.split slash p)
  where
    okComponent c =
      not (B.null c) && B.length c <= 255 && c /= "." && c /= ".."
        && B.all pchar c
    pchar b =
      (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57)
        || b == 95 || b == 46 || b == 43 || b == 45

-- | The first @/@-separated component of a path.
firstComponent :: B.ByteString -> B.ByteString
firstComponent = B.takeWhile (/= slash)

-- | A path in the reserved @out@ tree.
isGenerated :: Path -> Bool
isGenerated p = firstComponent p == "out"

-- | The path of the persisted build state.
stateFilePath :: Path
stateFilePath = ".kiln-state"

-- | @[A-Za-z_][A-Za-z0-9_]*@
isIdentShape :: B.ByteString -> Bool
isIdentShape s = case B.uncons s of
  Nothing -> False
  Just (c, rest) -> identStart c && B.all identChar rest
  where
    identStart c = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    identChar c = identStart c || (c >= 48 && c <= 57)

-- | @\@@ followed by an identifier-shaped name.
isPhonyShape :: B.ByteString -> Bool
isPhonyShape s = case BC.uncons s of
  Just ('@', rest) -> isIdentShape rest
  _ -> False
