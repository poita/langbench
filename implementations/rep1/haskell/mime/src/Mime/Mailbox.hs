-- | Reading mailboxes: mbox archives and directories of @.eml@ files.
module Mime.Mailbox
  ( Source (..)
  , splitMbox
  , readMailbox
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (isSuffixOf, sort)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

-- | One raw message and where it came from.
data Source = Source
  { sourceId :: String
  -- ^ the file name, or @mbox:N@ for the N-th message of an mbox
  , sourceBytes :: B.ByteString
  }
  deriving (Eq, Show)

-- | Split an mbox archive into its messages.
splitMbox :: B.ByteString -> [B.ByteString]
splitMbox bs = zipWith slice seps (map fst (drop 1 seps) ++ [n])
  where
    n = B.length bs
    slice (_, after) end = trim (B.take (end - after) (B.drop after bs))
    trim m
      | BC.isSuffixOf (BC.pack "\n\n") m = B.init m
      | otherwise = m
    -- (start of separator line, offset just after its terminator)
    seps = scan 0 True
    scan o prevEmpty
      | o >= n = []
      | otherwise =
          let rest = B.drop o bs
              (len, next) = case B.elemIndex 10 rest of
                Just i -> (i, o + i + 1)
                Nothing -> (B.length rest, n)
              line = B.take len rest
              isEmpty = B.null line || line == BC.pack "\r"
              isSep = prevEmpty && BC.pack "From " `B.isPrefixOf` line
           in [(o, next) | isSep] ++ scan next isEmpty

-- | Read the messages of a mailbox path.  A directory yields its @.eml@
-- regular files in byte order of their names; a regular file is an mbox.
readMailbox :: FilePath -> IO [Source]
readMailbox path = do
  isDir <- doesDirectoryExist path
  if isDir
    then do
      names <- sort . filter (".eml" `isSuffixOf`) <$> listDirectory path
      files <- filterM' (\f -> doesFileExist (path </> f)) names
      mapM (\f -> Source f <$> B.readFile (path </> f)) files
    else do
      bs <- B.readFile path
      pure (zipWith (\i m -> Source ("mbox:" ++ show i) m) [1 :: Int ..] (splitMbox bs))
  where
    filterM' p = fmap concat . mapM (\x -> (\b -> [x | b]) <$> p x)
