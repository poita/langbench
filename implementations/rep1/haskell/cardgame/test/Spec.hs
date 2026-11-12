module Main (main) where

import Test.Hspec

import qualified CardSpec
import qualified EngineSpec
import qualified GoldenSpec
import qualified MatchSpec
import qualified RandomSpec
import qualified SExprSpec

main :: IO ()
main = hspec $ do
  describe "Spiremark.SExpr" SExprSpec.spec
  describe "Spiremark.Random" RandomSpec.spec
  describe "Spiremark.Card" CardSpec.spec
  describe "Spiremark.Match" MatchSpec.spec
  describe "Spiremark.Engine" EngineSpec.spec
  describe "golden match files" GoldenSpec.spec
