-- | The virtual file system: a flat map from workspace paths to file
-- contents, with a lazily cached content hash per file, plus loading from and
-- writing to a real directory.
module Kiln.Workspace
  ( Workspace
  , File (..)
  , empty
  , fromList
  , toList
  , lookupFile
  , lookupContent
  , member
  , insert
  , delete
  , touch
  , removeGenerated
  , size
  , globCandidates
  , loadWorkspace
  , writeWorkspace
  ) where

import Control.Monad (filterM, forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , listDirectory
  )
import System.FilePath (takeDirectory, (</>))

import Kiln.Hash (Hash, fnv1a64)
import Kiln.Path (isGenerated, stateFilePath)

-- | A file's content, its hash (computed at most once per distinct content,
-- on first demand) and its modification stamp.  The stamp is never consulted
-- by change detection.
data File = File
  { fileContent :: !BS.ByteString
  , fileHash :: Hash
  , fileStamp :: !Int
  }

-- | The whole virtual file system.
data Workspace = Workspace
  { wsFiles :: !(Map BS.ByteString File)
  , _wsClock :: !Int
  }

empty :: Workspace
empty = Workspace Map.empty 0

mkFile :: Int -> BS.ByteString -> File
mkFile stamp c = File c (fnv1a64 c) stamp

-- | Build a workspace from (path, content) pairs.
fromList :: [(BS.ByteString, BS.ByteString)] -> Workspace
fromList = foldl (\w (p, c) -> insert p c w) empty

-- | All files in ascending path order.
toList :: Workspace -> [(BS.ByteString, File)]
toList = Map.toAscList . wsFiles

lookupFile :: BS.ByteString -> Workspace -> Maybe File
lookupFile p = Map.lookup p . wsFiles

lookupContent :: BS.ByteString -> Workspace -> Maybe BS.ByteString
lookupContent p w = fileContent <$> lookupFile p w

member :: BS.ByteString -> Workspace -> Bool
member p = Map.member p . wsFiles

-- | Write a file, replacing any previous content.
insert :: BS.ByteString -> BS.ByteString -> Workspace -> Workspace
insert p c (Workspace m t) = Workspace (Map.insert p (mkFile t c) m) (t + 1)

delete :: BS.ByteString -> Workspace -> Workspace
delete p w = w {wsFiles = Map.delete p (wsFiles w)}

-- | Update a file's modification stamp and nothing else.
touch :: BS.ByteString -> Workspace -> Workspace
touch p (Workspace m t) = Workspace (Map.adjust (\f -> f {fileStamp = t}) p m) (t + 1)

-- | Remove every generated path (and the state file); returns the removed
-- paths in ascending order together with the new workspace.
removeGenerated :: Workspace -> ([BS.ByteString], Workspace)
removeGenerated w = (removed, w {wsFiles = Map.withoutKeys (wsFiles w) (Map.keysSet doomed)})
  where
    doomed = Map.filterWithKey (\p _ -> isGenerated p || p == stateFilePath) (wsFiles w)
    removed = Map.keys doomed

size :: Workspace -> Int
size = Map.size . wsFiles

-- | Candidate paths for a glob whose wildcard-free prefix is given: the
-- eligible paths (not generated, not the state file) sharing that prefix, in
-- ascending order.  Costs O(log F) plus the size of the prefix range.
globCandidates :: BS.ByteString -> Workspace -> [BS.ByteString]
globCandidates prefix w =
  [ p
  | p <- Map.keys (Map.takeWhileAntitone (BS.isPrefixOf prefix) (Map.dropWhileAntitone (< prefix) (wsFiles w)))
  , not (isGenerated p)
  , p /= stateFilePath
  ]

-- | Load every regular file below a directory (except a top-level
-- @session.txt@) into a workspace.
loadWorkspace :: FilePath -> IO Workspace
loadWorkspace root = do
  entries <- walk ""
  files <- mapM (\rel -> (,) (BC.pack rel) <$> BS.readFile (root </> rel)) entries
  pure (fromList [(p, c) | (p, c) <- files, p /= "session.txt"])
  where
    walk rel = do
      names <- listDirectory (root </> rel)
      let rels = [if null rel then n else rel ++ "/" ++ n | n <- names]
      dirs <- filterM (doesDirectoryExist . (root </>)) rels
      let plain = filter (`notElem` dirs) rels
      sub <- mapM walk dirs
      pure (plain ++ concat sub)

-- | Write every file of the workspace under @dir/workspace/@.
writeWorkspace :: FilePath -> Workspace -> IO ()
writeWorkspace dir w = do
  createDirectoryIfMissing True dir
  forM_ (toList w) $ \(p, f) -> do
    let target = dir </> BC.unpack p
    createDirectoryIfMissing True (takeDirectory target)
    BS.writeFile target (fileContent f)
