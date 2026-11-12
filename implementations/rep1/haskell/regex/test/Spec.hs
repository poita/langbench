module Main (main) where

import Test.Hspec

import qualified BatchSpec
import qualified MatchSpec
import qualified ParserSpec
import qualified PropSpec

main :: IO ()
main = hspec $ do
  describe "Regex.Parser" ParserSpec.spec
  describe "Regex.search" MatchSpec.spec
  describe "Regex.Batch" BatchSpec.spec
  describe "properties" PropSpec.spec
