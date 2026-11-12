{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Fulltext.Corpus
-- Description : Reading the input directory and the query file.
module Fulltext.Corpus
  ( loadDocuments
  , QueryJob (..)
  , parseQueryFile
  , defaultLimit
  ) where

import Control.Monad (filterM)
import qualified Data.ByteString as B
import Data.Char (isDigit)
import Data.List (isSuffixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

import Fulltext.Analysis (isSpaceChar)

-- | Read @<root>/docs/*.txt@ as @(id, text)@ pairs.  A missing @docs@
-- directory yields no documents.  Invalid UTF-8 is replaced, not rejected.
loadDocuments :: FilePath -> IO [(Text, Text)]
loadDocuments root = do
  let dir = root </> "docs"
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      names <- filter (".txt" `isSuffixOf`) <$> listDirectory dir
      files <- filterM (doesFileExist . (dir </>)) names
      mapM load files
  where
    load name = do
      bytes <- B.readFile (root </> "docs" </> name)
      pure ( T.pack (take (length name - 4) name)
           , TE.decodeUtf8With TE.lenientDecode bytes )

-- | One query of @queries.txt@ with the result limit in force for it.
data QueryJob = QueryJob
  { jobNumber :: !Int   -- ^ 1-based query number
  , jobLimit  :: !Int   -- ^ the limit @k@
  , jobText   :: !Text  -- ^ the stripped query line
  } deriving (Eq, Show)

-- | The result limit before any @%k@ directive.
defaultLimit :: Int
defaultLimit = 10

-- | Parse @queries.txt@: blank lines and @#@ comments are skipped, @%k N@
-- sets the limit for the queries after it, everything else is a query.
parseQueryFile :: Text -> [QueryJob]
parseQueryFile = go 1 defaultLimit . map strip . T.splitOn "\n"
  where
    strip = T.dropAround isSpaceChar
    go :: Int -> Int -> [Text] -> [QueryJob]
    go _ _ [] = []
    go n k (l : ls)
      | T.null l || T.head l == '#' = go n k ls
      | Just k' <- directive l = go n k' ls
      | otherwise = QueryJob n k l : go (n + 1) k ls

-- | Recognise @%k@ followed by blanks, digits and optional blanks.
directive :: Text -> Maybe Int
directive l = do
  rest <- T.stripPrefix "%k" l
  let blank c = c == ' ' || c == '\t'
      (gap, r1) = T.span blank rest
      (ds, r2) = T.span isDigit r1
  if not (T.null gap) && not (T.null ds) && T.all blank r2
    then Just (fromInteger (min 1000000 (read (T.unpack ds))))
    else Nothing
