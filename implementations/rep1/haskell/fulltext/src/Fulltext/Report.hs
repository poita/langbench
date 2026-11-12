{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Fulltext.Report
-- Description : Rendering @results.txt@ and @stats.txt@.
module Fulltext.Report
  ( renderResults
  , renderStats
  , formatScore
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showFFloat)

import Fulltext
  ( Result (..) )
import Fulltext.Corpus (QueryJob (..))
import Fulltext.Index

-- | A score with exactly four digits after the decimal point.
formatScore :: Double -> Text
formatScore x = T.pack (showFFloat (Just 4) x "")

-- | The contents of @results.txt@.
renderResults :: [(QueryJob, [Result])] -> Text
renderResults = T.concat . map block
  where
    block (job, rs) = T.unlines $
      [ T.concat ["QUERY ", tshow (jobNumber job), " ", jobText job]
      , T.concat ["HITS ", tshow (length rs)] ]
      ++ [ T.intercalate "\t" [tshow r, resultDocId x, formatScore (resultScore x), resultSnippet x]
         | (r, x) <- zip [1 :: Int ..] rs ]

-- | The contents of @stats.txt@.
renderStats :: Index -> Text
renderStats ix = T.unlines
  [ "documents " <> tshow (numDocs ix)
  , "tokens " <> tshow (totalTokens ix)
  , "terms " <> tshow (numTerms ix)
  , "avgdl " <> formatScore (avgDocLength ix) ]

tshow :: Show a => a -> Text
tshow = T.pack . show
