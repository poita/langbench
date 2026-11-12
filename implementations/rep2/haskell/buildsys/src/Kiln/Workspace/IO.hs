-- | Loading a workspace from a real directory and writing one back.
module Kiln.Workspace.IO
  ( loadDirectory
  , writeDirectory
  ) where

import Control.Monad (forM, forM_)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import System.Directory
import System.FilePath ((</>), takeDirectory)

import Kiln.Workspace

-- | Recursively load every regular file below a directory. Paths are relative
-- to the directory and use @/@ as the separator. The top-level
-- @session.txt@ is returned separately and is not part of the workspace.
loadDirectory :: FilePath -> IO (Workspace, Maybe B.ByteString)
loadDirectory root = do
  files <- walk ""
  let session = lookup "session.txt" files
      ws = fromFiles [(BC.pack p, c) | (p, c) <- files, p /= "session.txt"]
  pure (ws, session)
  where
    walk rel = do
      let dir = if null rel then root else root </> rel
      names <- listDirectory dir
      fmap concat . forM names $ \n -> do
        let relN = if null rel then n else rel ++ "/" ++ n
        isDir <- doesDirectoryExist (root </> relN)
        if isDir
          then walk relN
          else do
            c <- B.readFile (root </> relN)
            pure [(relN, c)]

-- | Write every file of a workspace below @dir/prefix@, creating
-- intermediate directories.
writeDirectory :: FilePath -> Workspace -> IO ()
writeDirectory dir ws =
  forM_ (toFiles ws) $ \(p, c) -> do
    let target = dir </> BC.unpack p
    createDirectoryIfMissing True (takeDirectory target)
    B.writeFile target c
