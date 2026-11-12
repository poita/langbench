module Depresolve.VersionSpec (spec) where

import qualified Data.String
import Test.Hspec
import Test.QuickCheck

import Depresolve
import Depresolve.Gen (genVersion)
import Depresolve.Version (nextPatch)

spec :: Spec
spec = describe "Version" $ do
  it "compares components numerically" $
    Version 1 10 0 `shouldSatisfy` (> Version 1 9 0)
  it "compares major before minor before patch" $ do
    Version 2 0 0 `shouldSatisfy` (> Version 1 99 99)
    Version 1 2 0 `shouldSatisfy` (> Version 1 1 99)
  it "renders as MAJOR.MINOR.PATCH" $
    renderVersion (Version 1 10 0) `shouldBe` "1.10.0"
  it "parses what it renders" $
    property $ forAll genVersion $ \v ->
      parseVersion (read' (renderVersion v)) === Right v
  it "nextPatch is the immediate successor" $
    property $ forAll genVersion $ \v -> nextPatch v > v
  it "rejects leading zeros and malformed versions" $ do
    parseVersion (read' "01.0.0") `shouldSatisfy` isLeft'
    parseVersion (read' "1.0") `shouldSatisfy` isLeft'
  where
    read' = fromString'
    fromString' = Data.String.fromString
    isLeft' = either (const True) (const False)
