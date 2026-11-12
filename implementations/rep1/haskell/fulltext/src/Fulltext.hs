{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Fulltext
-- Description : A small positional full-text search engine with BM25 ranking.
--
-- > import qualified Data.Text as T
-- > import Fulltext
-- >
-- > main :: IO ()
-- > main = do
-- >   let ix = buildIndex [("note", "The quick brown fox jumps over the lazy dog.")]
-- >   mapM_ print (runQuery ix 10 "quick AND \"lazy dog\"")
--
-- The pipeline is: "Fulltext.Analysis" (tokenise, fold, stem with
-- "Fulltext.Porter") → "Fulltext.Index" (positional inverted index) →
-- "Fulltext.Query" (parse) → "Fulltext.Search" (match, score, rank) →
-- "Fulltext.Snippet" (best window).  "Fulltext.Corpus" and
-- "Fulltext.Report" handle the file formats of the command-line tool.
module Fulltext
  ( -- * Indexing
    Index
  , buildIndex
  , numDocs
  , totalTokens
  , numTerms
  , avgDocLength
    -- * Searching
  , Result (..)
  , runQuery
  , runParsedQuery
    -- * Re-exports
  , Query (..)
  , Atom (..)
  , parseQuery
  ) where

import Data.Text (Text)

import Fulltext.Index
import Fulltext.Query
import Fulltext.Search
import Fulltext.Snippet

-- | One ranked answer to a query.
data Result = Result
  { resultDocId   :: Text    -- ^ document id
  , resultScore   :: Double  -- ^ BM25 score
  , resultSnippet :: Text    -- ^ best-window snippet
  } deriving (Eq, Show)

-- | Parse and evaluate a query string, returning at most @k@ results ranked
-- by score, then document id.
runQuery :: Index -> Int -> Text -> [Result]
runQuery ix k = runParsedQuery ix k . parseQuery

-- | Evaluate an already parsed query ('Nothing' is the empty tree).
runParsedQuery :: Index -> Int -> Maybe Query -> [Result]
runParsedQuery ix k q =
  [ Result (docId d) (hitScore h) (snippet d (hitOccurrences h))
  | h <- search ix k q, let d = document ix (hitDoc h) ]
