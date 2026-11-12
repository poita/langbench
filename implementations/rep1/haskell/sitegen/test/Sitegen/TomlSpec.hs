{-# LANGUAGE OverloadedStrings #-}

module Sitegen.TomlSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import Sitegen.Toml

spec :: Spec
spec = do
  it "parses strings, integers, booleans and arrays in file order" $
    parseToml "title = \"A\"\nn = -4\nz = 0\ndraft = false\ntags = [\"a\", \"b\",]\n"
      `shouldBe` Right
        [ ("title", TomlString "A"), ("n", TomlInt (-4)), ("z", TomlInt 0)
        , ("draft", TomlBool False), ("tags", TomlArray ["a", "b"]) ]

  it "ignores blank lines and comments" $
    parseToml "\n  # note\n\t\nk = 1\n" `shouldBe` Right [("k", TomlInt 1)]

  it "handles the escapes of basic strings" $
    parseToml "s = \"q\\\" b\\\\ n\\n t\\t r\\r u\\u00e9\\u00E9\"\n"
      `shouldBe` Right [("s", TomlString "q\" b\\ n\n t\t r\r u\233\233")]

  it "does not treat # inside a string as a comment" $
    parseToml "a = \"x # y\"   # real comment\n" `shouldBe` Right [("a", TomlString "x # y")]

  it "allows whitespace around keys, values and array elements" $
    parseToml "  k\t=\t[ \"a\" ,\t\"b\" ]  \n" `shouldBe` Right [("k", TomlArray ["a", "b"])]

  it "parses an empty array" $
    parseToml "k = []\n" `shouldBe` Right [("k", TomlArray [])]

  it "accepts keys with digits, underscores and dashes" $
    parseToml "a-b_9 = true\n" `shouldBe` Right [("a-b_9", TomlBool True)]

  it "rejects leading zeros, unterminated strings and bad escapes" $ do
    parseToml "k = 01\n" `shouldSatisfy` isLeft
    parseToml "k = \"abc\n" `shouldSatisfy` isLeft
    parseToml "k = \"\\q\"\n" `shouldSatisfy` isLeft
    parseToml "k = 1 2\n" `shouldSatisfy` isLeft

  it "looks values up by type" $ do
    let doc = either error id (parseToml "s = \"x\"\ni = 3\nb = true\na = [\"p\"]\n")
    lookupString "s" doc `shouldBe` Just "x"
    lookupInt "i" doc `shouldBe` Just 3
    lookupBool "b" doc `shouldBe` Just True
    lookupStrings "a" doc `shouldBe` Just ["p"]
    lookupInt "s" doc `shouldBe` Nothing
