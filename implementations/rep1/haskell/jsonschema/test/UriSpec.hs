{-# LANGUAGE OverloadedStrings #-}
module UriSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import JsonSchema.Json (Value (..))
import JsonSchema.Pointer
import JsonSchema.Uri

-- The normal and abnormal examples of RFC 3986 section 5.4.
base :: Uri
base = parseUri "http://a/b/c/d;p?q"

res :: Text -> Text
res = renderUri . resolve base . parseUri

spec :: Spec
spec = do
  it "round-trips references" $ do
    mapM_ (\u -> renderUri (parseUri u) `shouldBe` u)
      ["http://a/b?c#d", "urn:uuid:1234", "#", "", "a/b:c", "//host", "x?"]

  it "resolves the RFC 3986 normal examples" $ do
    res "g:h" `shouldBe` "g:h"
    res "g" `shouldBe` "http://a/b/c/g"
    res "./g" `shouldBe` "http://a/b/c/g"
    res "g/" `shouldBe` "http://a/b/c/g/"
    res "/g" `shouldBe` "http://a/g"
    res "//g" `shouldBe` "http://g"
    res "?y" `shouldBe` "http://a/b/c/d;p?y"
    res "g?y" `shouldBe` "http://a/b/c/g?y"
    res "#s" `shouldBe` "http://a/b/c/d;p?q#s"
    res "g#s" `shouldBe` "http://a/b/c/g#s"
    res "" `shouldBe` "http://a/b/c/d;p?q"
    res "." `shouldBe` "http://a/b/c/"
    res ".." `shouldBe` "http://a/b/"
    res "../g" `shouldBe` "http://a/b/g"
    res "../.." `shouldBe` "http://a/"
    res "../../g" `shouldBe` "http://a/g"

  it "resolves the RFC 3986 abnormal examples" $ do
    res "../../../g" `shouldBe` "http://a/g"
    res "/./g" `shouldBe` "http://a/g"
    res "g." `shouldBe` "http://a/b/c/g."
    res "./g/." `shouldBe` "http://a/b/c/g/"
    res "g/./h" `shouldBe` "http://a/b/c/g/h"
    res "g/../h" `shouldBe` "http://a/b/c/h"
    res "http:g" `shouldBe` "http:g"

  it "resolves against the empty base" $
    renderUri (resolve (parseUri "") (parseUri "foo.json#/a")) `shouldBe` "foo.json#/a"

  it "splits off and decodes fragments" $ do
    splitFragment (parseUri "http://x/y#/a%25b/%C3%A9") `shouldBe` ("http://x/y", "/a%b/\233")
    splitFragment (parseUri "http://x/y") `shouldBe` ("http://x/y", "")

  it "parses and evaluates JSON pointers" $ do
    parsePointer "/a~1b/~0" `shouldBe` Just ["a/b", "~"]
    parsePointer "" `shouldBe` Just []
    parsePointer "a" `shouldBe` Nothing
    escapeToken "a/b~" `shouldBe` "a~1b~0"
    evalPointer "/0" (Arr [Null]) `shouldBe` Just Null
    evalPointer "/1" (Arr [Null]) `shouldBe` Nothing
