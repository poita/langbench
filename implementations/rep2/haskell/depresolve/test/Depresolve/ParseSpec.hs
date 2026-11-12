{-# LANGUAGE OverloadedStrings #-}
module Depresolve.ParseSpec (spec) where

import Test.Hspec

import Depresolve

spec :: Spec
spec = describe "parseProblem" $ do
  it "parses an empty root" $
    parseProblem "root:\n" `shouldBe` Right (Problem [] [])
  it "parses registry lines and the root" $
    parseProblem "a 1.0.0: b ^1.0.0, c *\nb 1.2.3:\nroot: a >=1.0.0 <2.0.0\n"
      `shouldBe` Right
        (Problem
          [ PackageVersion "a" (Version 1 0 0)
              [Requirement "b" (Caret (Version 1 0 0)), Requirement "c" Any]
          , PackageVersion "b" (Version 1 2 3) []
          ]
          [Requirement "a" (Comparators [Comparator Ge (Version 1 0 0), Comparator Lt (Version 2 0 0)])])
  it "reports a missing root line" $
    parseProblem "" `shouldSatisfy` either (const True) (const False)
  it "reports malformed lines with their number" $
    parseProblem "a 1.0.0 b *\nroot:\n" `shouldSatisfy` either (("line 1" ==) . take 6) (const False)
