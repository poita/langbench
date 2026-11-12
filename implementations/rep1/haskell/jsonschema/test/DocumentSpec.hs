{-# LANGUAGE OverloadedStrings #-}
module DocumentSpec (spec) where

import qualified Data.ByteString.Char8 as B8
import Test.Hspec

import JsonSchema

spec :: Spec
spec = do
  it "prints one verdict per test (SPEC section 2)" $
    processBytes
      (B8.pack "{\"schema\":{\"type\":\"integer\",\"minimum\":1},\"tests\":[{\"description\":\"a\",\"data\":3},{\"description\":\"b\",\"data\":0},{\"description\":\"c\",\"data\":\"3\"}]}")
      `shouldBe` Right "valid\ninvalid\ninvalid\n"

  it "ignores extra members and accepts an empty test list" $
    processBytes (B8.pack "{\"schema\":true,\"extra\":1,\"tests\":[]}") `shouldBe` Right ""

  it "reports malformed documents" $ do
    processBytes (B8.pack "{") `shouldSatisfy` isLeft'
    processBytes (B8.pack "[]") `shouldSatisfy` isLeft'
    processBytes (B8.pack "{\"schema\":true}") `shouldSatisfy` isLeft'
  where
    isLeft' = either (const True) (const False)
