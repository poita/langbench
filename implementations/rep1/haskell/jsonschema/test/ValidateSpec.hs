{-# LANGUAGE OverloadedStrings #-}
module ValidateSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import JsonSchema

parse :: Text -> Value
parse t = either (error . show) id (parseJson t)

-- | Validate an instance against a schema (given as JSON text).
check :: Text -> Text -> Bool
check = checkWith []

checkWith :: [(Text, Text)] -> Text -> Text -> Bool
checkWith remotes schema inst =
  validate (compileSchema (parse schema) [(u, parse d) | (u, d) <- remotes]) (parse inst)

spec :: Spec
spec = do
  describe "basic keywords" $ do
    it "boolean schemas" $ do
      check "true" "1" `shouldBe` True
      check "false" "1" `shouldBe` False
    it "type" $ do
      check "{\"type\":\"integer\"}" "1.0" `shouldBe` True
      check "{\"type\":\"integer\"}" "1.5" `shouldBe` False
      check "{\"type\":[\"string\",\"null\"]}" "null" `shouldBe` True
      check "{\"type\":\"number\"}" "true" `shouldBe` False
    it "enum and const use JSON equality" $ do
      check "{\"enum\":[1,\"1\",null,[1],{\"a\":1}]}" "1.0" `shouldBe` True
      check "{\"enum\":[1,\"1\",null,[1],{\"a\":1}]}" "{\"a\":1.000}" `shouldBe` True
      check "{\"enum\":[1]}" "true" `shouldBe` False
      check "{\"const\":0}" "false" `shouldBe` False
    it "multipleOf is exact" $ do
      check "{\"multipleOf\":0.0001}" "0.3" `shouldBe` True
      check "{\"multipleOf\":0.0001}" "0.00005" `shouldBe` False
    it "bounds are exact" $ do
      check "{\"maximum\":1e308}" "1e309" `shouldBe` False
      check "{\"exclusiveMinimum\":0}" "0" `shouldBe` False
    it "string length counts code points" $ do
      check "{\"maxLength\":1}" "\"\128169\"" `shouldBe` True
      check "{\"minLength\":2.0}" "\"\233\"" `shouldBe` False
    it "pattern searches" $ do
      check "{\"pattern\":\"bar\"}" "\"foobarbaz\"" `shouldBe` True
      check "{\"pattern\":\"^bar\"}" "\"foobar\"" `shouldBe` False
    it "format never rejects" $
      check "{\"type\":\"string\",\"format\":\"ipv4\"}" "\"nope\"" `shouldBe` True
    it "unknown keywords are inert" $
      check "{\"definitions\":{\"a\":false},\"foo\":{\"type\":\"string\"}}" "1" `shouldBe` True

  describe "arrays" $ do
    it "uniqueItems ignores key order and distinguishes types" $ do
      check "{\"uniqueItems\":true}" "[{\"a\":1,\"b\":2},{\"b\":2,\"a\":1}]" `shouldBe` False
      check "{\"uniqueItems\":true}" "[1,true,\"1\"]" `shouldBe` True
      check "{\"uniqueItems\":true}" "[1,1.0]" `shouldBe` False
    it "prefixItems / items" $ do
      let s = "{\"prefixItems\":[{\"type\":\"integer\"}],\"items\":{\"type\":\"string\"}}"
      check s "[1,\"a\"]" `shouldBe` True
      check s "[1,2]" `shouldBe` False
    it "contains with counts" $ do
      let s = "{\"contains\":{\"type\":\"integer\"},\"minContains\":2,\"maxContains\":3}"
      check s "[1,\"a\",2]" `shouldBe` True
      check s "[1,\"a\"]" `shouldBe` False
      check s "[1,2,3,4]" `shouldBe` False
      check "{\"contains\":false,\"minContains\":0}" "[1]" `shouldBe` True

  describe "objects" $ do
    it "properties, patternProperties, additionalProperties" $ do
      let s = "{\"properties\":{\"a\":{\"type\":\"integer\"}},\"patternProperties\":{\"^x\":{\"type\":\"string\"}},\"additionalProperties\":false}"
      check s "{\"a\":1,\"xy\":\"s\"}" `shouldBe` True
      check s "{\"a\":1,\"xy\":1}" `shouldBe` False
      check s "{\"b\":1}" `shouldBe` False
    it "required / dependentRequired / propertyNames" $ do
      check "{\"required\":[\"a\"]}" "{}" `shouldBe` False
      check "{\"required\":[\"a\"]}" "[]" `shouldBe` True
      check "{\"dependentRequired\":{\"a\":[\"b\"]}}" "{\"a\":1}" `shouldBe` False
      check "{\"propertyNames\":{\"maxLength\":2}}" "{\"abc\":1}" `shouldBe` False

  describe "applicators and annotations" $ do
    it "oneOf requires exactly one" $ do
      check "{\"oneOf\":[{\"type\":\"integer\"},{\"minimum\":2}]}" "3" `shouldBe` False
      check "{\"oneOf\":[{\"type\":\"integer\"},{\"minimum\":2}]}" "1" `shouldBe` True
    it "if/then/else" $ do
      let s = "{\"if\":{\"minimum\":0},\"then\":{\"maximum\":10},\"else\":{\"multipleOf\":2}}"
      check s "5" `shouldBe` True
      check s "11" `shouldBe` False
      check s "-3" `shouldBe` False
    it "unevaluatedProperties sees through allOf and if/then (SPEC 7.1)" $ do
      let s = "{\"allOf\":[{\"properties\":{\"a\":{\"type\":\"integer\"}}},{\"properties\":{\"b\":{\"type\":\"integer\"}}}],\"if\":{\"required\":[\"a\"]},\"then\":{\"properties\":{\"c\":{\"type\":\"string\"}}},\"unevaluatedProperties\":false}"
      check s "{\"a\":1,\"b\":2}" `shouldBe` True
      check s "{\"a\":1,\"c\":\"yes\"}" `shouldBe` True
      check s "{\"b\":2,\"c\":\"yes\"}" `shouldBe` False
      check s "{\"a\":1,\"d\":0}" `shouldBe` False
    it "annotations from rejected branches are dropped" $
      check "{\"anyOf\":[{\"properties\":{\"a\":true},\"required\":[\"z\"]},{\"required\":[\"b\"]}],\"unevaluatedProperties\":false}" "{\"a\":1,\"b\":1}" `shouldBe` False
    it "unevaluatedItems after prefixItems and contains" $ do
      check "{\"prefixItems\":[true],\"unevaluatedItems\":false}" "[1]" `shouldBe` True
      check "{\"prefixItems\":[true],\"unevaluatedItems\":false}" "[1,2]" `shouldBe` False
      check "{\"contains\":{\"type\":\"string\"},\"unevaluatedItems\":false}" "[\"a\",\"b\"]" `shouldBe` True
      check "{\"contains\":{\"type\":\"string\"},\"unevaluatedItems\":false}" "[\"a\",1]" `shouldBe` False

  describe "references" $ do
    it "$ref with siblings and $defs" $ do
      let s = "{\"$defs\":{\"pos\":{\"minimum\":1}},\"$ref\":\"#/$defs/pos\",\"maximum\":5}"
      check s "3" `shouldBe` True
      check s "0" `shouldBe` False
      check s "6" `shouldBe` False
    it "JSON pointers unescape and percent-decode" $ do
      let s = "{\"$defs\":{\"a/b\":{\"type\":\"string\"},\"c d\":{\"type\":\"null\"}},\"properties\":{\"x\":{\"$ref\":\"#/$defs/a~1b\"},\"y\":{\"$ref\":\"#/$defs/c%20d\"}}}"
      check s "{\"x\":\"s\",\"y\":null}" `shouldBe` True
      check s "{\"x\":1}" `shouldBe` False
    it "recursion through #" $
      check "{\"properties\":{\"n\":{\"$ref\":\"#\"}},\"type\":\"object\"}" "{\"n\":{\"n\":1}}" `shouldBe` False
    it "$anchor" $
      check "{\"$defs\":{\"a\":{\"$anchor\":\"foo\",\"type\":\"integer\"}},\"$ref\":\"#foo\"}" "\"x\"" `shouldBe` False
    it "relative references follow $id and remotes (SPEC 7.4)" $ do
      let s = "{\"$id\":\"http://localhost:1234/draft2020-12/root-of-its-own.json\",\"type\":\"object\",\"properties\":{\"i\":{\"$ref\":\"integer.json\"},\"n\":{\"$ref\":\"subSchemas.json#/$defs/integer\"}}}"
          remotes =
            [ ("http://localhost:1234/draft2020-12/integer.json", "{\"type\":\"integer\"}")
            , ("http://localhost:1234/draft2020-12/subSchemas.json", "{\"$defs\":{\"integer\":{\"type\":\"integer\"}}}")
            ]
      checkWith remotes s "{\"i\":1,\"n\":2}" `shouldBe` True
      checkWith remotes s "{\"i\":\"1\"}" `shouldBe` False
    it "$id is not recognised inside data" $
      check "{\"const\":{\"$id\":\"http://x/y\"},\"$ref\":\"#/$defs/a\",\"$defs\":{\"a\":true}}" "{\"$id\":\"http://x/y\"}" `shouldBe` True
    it "$dynamicRef resolves to the outermost dynamic anchor (SPEC 6.5)" $ do
      let s = "{\"$id\":\"https://example.test/strings\",\"$defs\":{\"itemType\":{\"$dynamicAnchor\":\"itemType\",\"type\":\"string\"},\"list\":{\"$id\":\"https://example.test/list\",\"$defs\":{\"itemType\":{\"$dynamicAnchor\":\"itemType\"}},\"type\":\"array\",\"items\":{\"$dynamicRef\":\"#itemType\"}}},\"$ref\":\"https://example.test/list\"}"
      check s "[\"a\",\"b\"]" `shouldBe` True
      check s "[\"a\",1]" `shouldBe` False
    it "$dynamicRef without a dynamic anchor behaves like $ref" $
      check "{\"$defs\":{\"a\":{\"$anchor\":\"a\",\"type\":\"integer\"}},\"$dynamicRef\":\"#a\"}" "\"x\"" `shouldBe` False
    it "unresolvable references reject" $
      check "{\"$ref\":\"nowhere.json\"}" "1" `shouldBe` False
