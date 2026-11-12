{-# LANGUAGE OverloadedStrings #-}
module JsonSpec (spec) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Test.Hspec

import Toml

render :: Table -> BL.ByteString
render = B.toLazyByteString . renderTaggedJson

spec :: Spec
spec = do
  it "renders compact, key-sorted JSON" $
    render (Map.fromList [("b", vInteger 1), ("A", VArray [vBool True]), ("\233", vString "x")])
      `shouldBe` "{\"A\":[{\"type\":\"bool\",\"value\":\"true\"}],\"b\":{\"type\":\"integer\",\"value\":\"1\"},\"\195\169\":{\"type\":\"string\",\"value\":\"x\"}}"
  it "escapes control characters but not DEL or non-ASCII" $
    render (Map.fromList [("k", vString "\"\\\b\f\n\r\t\1\DEL\233")])
      `shouldBe` "{\"k\":{\"type\":\"string\",\"value\":\"\\\"\\\\\\b\\f\\n\\r\\t\\u0001\DEL\195\169\"}}"
  it "reads JSON with arbitrary whitespace, member order and escapes" $
    parseTaggedJson " { \"b\" : { \"value\" : \"a\\u00e9\\ud83d\\ude00\\/\" , \"type\":\"string\" },\n \"a\":[ ] } "
      `shouldBe` Right (Map.fromList [("a", VArray []), ("b", vString "a\233\128512/")])
  it "treats a table with keys type and value as a table" $
    parseTaggedJson "{\"type\":{\"type\":\"bool\",\"value\":\"true\"},\"value\":{\"type\":\"bool\",\"value\":\"false\"}}"
      `shouldBe` Right (Map.fromList [("type", vBool True), ("value", vBool False)])
  it "rejects malformed JSON" $ do
    parseTaggedJson "{" `shouldSatisfy` either (const True) (const False)
    parseTaggedJson "[]" `shouldSatisfy` either (const True) (const False)
