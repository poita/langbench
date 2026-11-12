-- |
-- Module      : Git.Ref
-- Description : Looking refs up on disk (loose files, then @packed-refs@).
module Git.Ref
  ( resolveRef
  , validRefName
  , bytesToPath
  ) where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as Map
import GHC.IO.Encoding (getFileSystemEncoding)
import qualified GHC.Foreign as GHC
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Git.Store (Repository, repoPackedRefs, repoPath)
import Git.Types

-- | Is this a name that may be looked up?  Only @HEAD@ and names under
-- @refs/@, with no empty, @.@ or @..@ component and no NUL byte.
validRefName :: ByteString -> Bool
validRefName name =
  (name == BC.pack "HEAD" || BC.pack "refs/" `BS.isPrefixOf` name)
    && BS.notElem 0 name
    && all ok (BS.split 47 name)
  where
    ok c = not (BS.null c) && c /= BC.pack "." && c /= BC.pack ".."

-- | Convert bytes to a 'FilePath' so that the same bytes are used on disk,
-- whether or not they are valid UTF-8.
bytesToPath :: ByteString -> IO FilePath
bytesToPath b = do
  enc <- getFileSystemEncoding
  BS.useAsCStringLen b (GHC.peekCStringLen enc)

-- | Resolve a full ref name (@HEAD@, @refs/heads/main@, ...) to the id it
-- holds.  The loose file wins over @packed-refs@; symbolic refs
-- (@ref: \<name\>@) are followed at most 5 times.  The id is taken at face
-- value: the object need not exist.
resolveRef :: Repository -> ByteString -> IO (Maybe ObjectId)
resolveRef repo = go (0 :: Int)
  where
    go depth name
      | not (validRefName name) = pure Nothing
      | otherwise = do
          rel <- bytesToPath name
          let path = repoPath repo </> rel
          exists <- doesFileExist path
          if exists
            then do
              r <- try (BS.readFile path)
              case r :: Either IOException ByteString of
                Left _ -> pure Nothing
                Right content -> follow depth (BS.dropWhileEnd isSpace content)
            else pure (Map.lookup name (repoPackedRefs repo))
    follow depth content
      | Just target <- BS.stripPrefix (BC.pack "ref: ") content =
          if depth >= 5 then pure Nothing else go (depth + 1) target
      | BS.length content == 40 && BC.all (`elem` "0123456789abcdef") content = pure (objectIdFromHex content)
      | otherwise = pure Nothing
    isSpace c = c == 32 || (c >= 9 && c <= 13)
