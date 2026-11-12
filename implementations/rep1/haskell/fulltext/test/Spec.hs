module Main (main) where

import Test.Hspec

import qualified AnalysisSpec
import qualified CorpusSpec
import qualified EndToEndSpec
import qualified IndexSpec
import qualified PorterSpec
import qualified QuerySpec
import qualified SearchSpec
import qualified SnippetSpec

main :: IO ()
main = hspec $ do
  describe "Fulltext.Analysis" AnalysisSpec.spec
  describe "Fulltext.Porter" PorterSpec.spec
  describe "Fulltext.Query" QuerySpec.spec
  describe "Fulltext.Index" IndexSpec.spec
  describe "Fulltext.Search" SearchSpec.spec
  describe "Fulltext.Snippet" SnippetSpec.spec
  describe "Fulltext.Corpus" CorpusSpec.spec
  describe "end to end" EndToEndSpec.spec
