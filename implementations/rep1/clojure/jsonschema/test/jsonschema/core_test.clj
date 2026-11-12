(ns jsonschema.core-test
  (:require [clojure.test :refer [deftest is testing are]]
            [jsonschema.core :as js]
            [jsonschema.json :as json]))

(defn- check
  "Validates the JSON text `instance` against the JSON text `schema`."
  ([schema instance] (check schema instance nil))
  ([schema instance remotes]
   (js/valid? (js/validator (json/parse schema)
                            {:remotes (when remotes (json/parse remotes))})
              (json/parse instance))))

(deftest boolean-schemas
  (is (check "true" "[1]"))
  (is (not (check "false" "null")))
  (is (check "{}" "{\"a\":1}")))

(deftest types
  (are [schema inst expected] (= expected (check schema inst))
    "{\"type\":\"integer\"}" "1.0" true
    "{\"type\":\"integer\"}" "1.5" false
    "{\"type\":\"integer\"}" "1e2" true
    "{\"type\":\"number\"}" "true" false
    "{\"type\":[\"string\",\"null\"]}" "null" true
    "{\"type\":[\"string\",\"null\"]}" "1" false
    "{\"type\":\"array\"}" "{}" false
    "{\"type\":\"object\"}" "[]" false
    "{\"type\":\"boolean\"}" "false" true))

(deftest equality-keywords
  (are [schema inst expected] (= expected (check schema inst))
    "{\"enum\":[1,\"1\",null,[1],{\"a\":1}]}" "1" true
    "{\"enum\":[1,\"1\",null,[1],{\"a\":1}]}" "1.0" true
    "{\"enum\":[1,\"1\",null,[1],{\"a\":1}]}" "{\"a\":1.000}" true
    "{\"enum\":[1,\"1\",null,[1],{\"a\":1}]}" "true" false
    "{\"enum\":[1,\"1\",null,[1],{\"a\":1}]}" "false" false
    "{\"enum\":[1,\"1\",null,[1],{\"a\":1}]}" "[2]" false
    "{\"const\":0}" "false" false
    "{\"const\":{\"a\":[1,2]}}" "{\"a\":[1.0,2]}" true))

(deftest numeric-keywords
  (are [schema inst expected] (= expected (check schema inst))
    "{\"multipleOf\":0.0001}" "0.3" true
    "{\"multipleOf\":0.0001}" "0.0021" true
    "{\"multipleOf\":2}" "7" false
    "{\"multipleOf\":2}" "\"x\"" true
    "{\"maximum\":1e308}" "1e309" false
    "{\"minimum\":-1e308}" "-1e309" false
    "{\"exclusiveMinimum\":1}" "1.0" false
    "{\"exclusiveMaximum\":1}" "0.999999999999999999999" true
    "{\"minimum\":1,\"maximum\":3}" "3" true))

(deftest string-keywords
  (are [schema inst expected] (= expected (check schema inst))
    "{\"maxLength\":1}" "\"💩\"" true
    "{\"minLength\":2}" "\"💩\"" false
    "{\"maxLength\":2.0}" "\"abc\"" false
    "{\"minLength\":2e0}" "\"abc\"" true
    "{\"pattern\":\"bar\"}" "\"foobarbaz\"" true
    "{\"pattern\":\"^bar\"}" "\"foobarbaz\"" false
    "{\"pattern\":\"^a$\"}" "\"a\\n\"" false
    "{\"pattern\":\"\\\\bcat\\\\b\"}" "\"écat \"" true
    "{\"pattern\":\"a\"}" "1" true))

(deftest array-keywords
  (are [schema inst expected] (= expected (check schema inst))
    "{\"minItems\":2}" "[1]" false
    "{\"maxItems\":1}" "[1]" true
    "{\"uniqueItems\":true}" "[1,2,1.0]" false
    "{\"uniqueItems\":true}" "[0,false]" true
    "{\"uniqueItems\":false}" "[1,1]" true
    "{\"prefixItems\":[{\"type\":\"integer\"},{\"type\":\"string\"}]}" "[1,\"a\",null]" true
    "{\"prefixItems\":[{\"type\":\"integer\"}],\"items\":false}" "[1,2]" false
    "{\"prefixItems\":[{\"type\":\"integer\"}],\"items\":{\"type\":\"string\"}}" "[1,\"x\"]" true
    "{\"items\":{\"type\":\"integer\"}}" "[1,\"x\"]" false
    "{\"items\":{\"type\":\"integer\"}}" "{}" true))

(deftest contains-keywords
  (let [s "{\"type\":\"array\",\"contains\":{\"type\":\"integer\"},\"minContains\":2,\"maxContains\":3}"]
    (is (check s "[1,\"a\",2]"))
    (is (check s "[\"a\",1,2,3,\"b\"]"))
    (is (not (check s "[1,\"a\"]")))
    (is (not (check s "[1,2,3,4]"))))
  (is (check "{\"contains\":{\"type\":\"integer\"},\"minContains\":0}" "[]"))
  (is (not (check "{\"contains\":{\"type\":\"integer\"}}" "[]")))
  (is (check "{\"minContains\":3}" "[]") "minContains alone is inert"))

(deftest object-keywords
  (are [schema inst expected] (= expected (check schema inst))
    "{\"required\":[\"a\"]}" "{}" false
    "{\"required\":[\"a\"]}" "[]" true
    "{\"minProperties\":1}" "{}" false
    "{\"maxProperties\":1}" "{\"a\":1,\"b\":2}" false
    "{\"dependentRequired\":{\"a\":[\"b\"]}}" "{\"a\":1}" false
    "{\"dependentRequired\":{\"a\":[\"b\"]}}" "{\"b\":1}" true
    "{\"properties\":{\"a\":{\"type\":\"integer\"}}}" "{\"a\":\"x\"}" false
    "{\"properties\":{\"a\":{\"type\":\"integer\"}}}" "{\"b\":\"x\"}" true
    "{\"patternProperties\":{\"^a\":{\"type\":\"integer\"},\"b$\":{\"minimum\":5}}}" "{\"ab\":3}" false
    "{\"patternProperties\":{\"^a\":{\"type\":\"integer\"},\"b$\":{\"minimum\":5}}}" "{\"ab\":7}" true
    "{\"properties\":{\"a\":true},\"patternProperties\":{\"^x\":true},\"additionalProperties\":false}" "{\"a\":1,\"xy\":2}" true
    "{\"properties\":{\"a\":true},\"patternProperties\":{\"^x\":true},\"additionalProperties\":false}" "{\"a\":1,\"z\":2}" false
    "{\"additionalProperties\":{\"type\":\"string\"}}" "{\"a\":\"s\",\"b\":1}" false
    "{\"propertyNames\":{\"maxLength\":2}}" "{\"ab\":1,\"abc\":2}" false
    "{\"propertyNames\":{\"maxLength\":3}}" "{\"ab\":1,\"abc\":2}" true
    "{\"dependentSchemas\":{\"a\":{\"required\":[\"b\"]}}}" "{\"a\":1}" false
    "{\"dependentSchemas\":{\"a\":{\"required\":[\"b\"]}}}" "{\"c\":1}" true))

(deftest in-place-applicators
  (are [schema inst expected] (= expected (check schema inst))
    "{\"allOf\":[{\"type\":\"integer\"},{\"minimum\":2}]}" "1" false
    "{\"anyOf\":[{\"type\":\"string\"},{\"minimum\":2}]}" "3" true
    "{\"anyOf\":[{\"type\":\"string\"},{\"minimum\":2}]}" "1" false
    "{\"oneOf\":[{\"type\":\"integer\"},{\"minimum\":2}]}" "3" false
    "{\"oneOf\":[{\"type\":\"integer\"},{\"minimum\":2}]}" "1" true
    "{\"not\":{\"type\":\"string\"}}" "1" true
    "{\"not\":{\"type\":\"string\"}}" "\"s\"" false
    "{\"if\":{\"minimum\":10},\"then\":{\"multipleOf\":5}}" "11" false
    "{\"if\":{\"minimum\":10},\"then\":{\"multipleOf\":5}}" "3" true
    "{\"if\":{\"minimum\":10},\"else\":{\"multipleOf\":2}}" "3" false
    "{\"then\":false}" "1" true
    "{\"else\":false}" "1" true))

(deftest inert-keywords
  (are [schema inst] (check schema inst)
    "{\"format\":\"ipv4\",\"type\":\"string\"}" "\"nope\""
    "{\"definitions\":{\"x\":false},\"dependencies\":{\"a\":false},\"title\":1}" "{\"a\":1}"
    "{\"$defs\":{\"x\":false},\"$comment\":\"c\",\"default\":1,\"examples\":[1]}" "1"
    "{\"contentEncoding\":\"base64\",\"contentMediaType\":\"x/y\",\"contentSchema\":false}" "\"!\""
    "{\"$vocabulary\":{\"https://json-schema.org/draft/2020-12/vocab/validation\":false},\"minimum\":1}" "5"
    "{\"invented\":{\"type\":\"string\"}}" "1"))

(deftest unevaluated-properties
  (let [s "{\"allOf\":[{\"properties\":{\"a\":{\"type\":\"integer\"}}},{\"properties\":{\"b\":{\"type\":\"integer\"}}}],
            \"if\":{\"required\":[\"a\"]},
            \"then\":{\"properties\":{\"c\":{\"type\":\"string\"}}},
            \"unevaluatedProperties\":false}"]
    (is (check s "{\"a\":1,\"b\":2}"))
    (is (check s "{\"a\":1,\"c\":\"yes\"}"))
    (is (not (check s "{\"b\":2,\"c\":\"yes\"}")))
    (is (not (check s "{\"a\":1,\"d\":0}"))))
  (testing "anyOf contributes only the branches that accepted"
    (let [s "{\"anyOf\":[{\"properties\":{\"a\":{\"type\":\"string\"}}},{\"properties\":{\"b\":true}}],\"unevaluatedProperties\":false}"]
      (is (check s "{\"a\":\"x\",\"b\":1}"))
      (is (not (check s "{\"a\":1,\"b\":1}")) "a is only evaluated by the branch that rejected")
      (is (not (check s "{\"a\":1}")))))
  (testing "not contributes nothing"
    (is (not (check "{\"not\":{\"not\":{\"properties\":{\"a\":true}}},\"unevaluatedProperties\":false}" "{\"a\":1}"))))
  (testing "a failing schema object produces no annotations"
    (is (not (check "{\"allOf\":[{\"properties\":{\"a\":true},\"required\":[\"z\"]}],\"unevaluatedProperties\":false}" "{\"a\":1}"))))
  (testing "unevaluatedProperties with a schema"
    (is (check "{\"properties\":{\"a\":true},\"unevaluatedProperties\":{\"type\":\"integer\"}}" "{\"a\":\"s\",\"b\":1}"))
    (is (not (check "{\"properties\":{\"a\":true},\"unevaluatedProperties\":{\"type\":\"integer\"}}" "{\"a\":1,\"b\":\"s\"}")))))

(deftest unevaluated-items
  (are [schema inst expected] (= expected (check schema inst))
    "{\"prefixItems\":[true],\"unevaluatedItems\":false}" "[1]" true
    "{\"prefixItems\":[true],\"unevaluatedItems\":false}" "[1,2]" false
    "{\"items\":true,\"unevaluatedItems\":false}" "[1,2]" true
    "{\"contains\":{\"type\":\"string\"},\"unevaluatedItems\":false}" "[\"a\",\"b\"]" true
    "{\"contains\":{\"type\":\"string\"},\"unevaluatedItems\":false}" "[\"a\",1]" false
    "{\"allOf\":[{\"prefixItems\":[true]}],\"unevaluatedItems\":{\"type\":\"string\"}}" "[1,\"a\"]" true
    "{\"allOf\":[{\"prefixItems\":[true]}],\"unevaluatedItems\":{\"type\":\"string\"}}" "[1,2]" false))

(deftest references
  (testing "$ref with siblings and $defs"
    (let [s "{\"$defs\":{\"pos\":{\"type\":\"integer\",\"minimum\":1}},\"properties\":{\"n\":{\"$ref\":\"#/$defs/pos\",\"maximum\":5}}}"]
      (is (check s "{\"n\":3}"))
      (is (not (check s "{\"n\":6}")))
      (is (not (check s "{\"n\":0}")))))
  (testing "recursive $ref to the root"
    (let [s "{\"type\":\"object\",\"properties\":{\"next\":{\"$ref\":\"#\"}},\"required\":[\"v\"]}"]
      (is (check s "{\"v\":1,\"next\":{\"v\":2}}"))
      (is (not (check s "{\"v\":1,\"next\":{}}")))))
  (testing "JSON pointer escapes and percent-decoding"
    (let [s "{\"$defs\":{\"a/b\":{\"type\":\"integer\"},\"c~d\":{\"type\":\"string\"},\"e f\":{\"type\":\"null\"}},
              \"properties\":{\"x\":{\"$ref\":\"#/$defs/a~1b\"},\"y\":{\"$ref\":\"#/$defs/c~0d\"},\"z\":{\"$ref\":\"#/$defs/e%20f\"}}}"]
      (is (check s "{\"x\":1,\"y\":\"s\",\"z\":null}"))
      (is (not (check s "{\"x\":\"s\"}")))
      (is (not (check s "{\"z\":1}")))))
  (testing "$anchor"
    (let [s "{\"$defs\":{\"a\":{\"$anchor\":\"foo\",\"type\":\"integer\"}},\"$ref\":\"#foo\"}"]
      (is (check s "1"))
      (is (not (check s "\"x\"")))))
  (testing "$id changes the base"
    (let [s "{\"$id\":\"http://localhost:1234/draft2020-12/root-of-its-own.json\",\"type\":\"object\",
              \"properties\":{\"i\":{\"$ref\":\"integer.json\"},\"n\":{\"$ref\":\"subSchemas.json#/$defs/integer\"}}}"
          remotes "{\"http://localhost:1234/draft2020-12/integer.json\":{\"type\":\"integer\"},
                    \"http://localhost:1234/draft2020-12/subSchemas.json\":{\"$defs\":{\"integer\":{\"type\":\"integer\"}}}}"]
      (is (check s "{\"i\":1,\"n\":2}" remotes))
      (is (not (check s "{\"i\":\"1\"}" remotes)))
      (is (not (check s "{\"n\":\"1\"}" remotes)))))
  (testing "embedded resources and nested $id"
    (let [s "{\"$id\":\"http://x/root\",\"$defs\":{\"inner\":{\"$id\":\"http://x/inner/\",\"$defs\":{\"t\":{\"type\":\"string\"}},\"properties\":{\"a\":{\"$ref\":\"#/$defs/t\"}}}},\"$ref\":\"http://x/inner/\"}"]
      (is (check s "{\"a\":\"s\"}"))
      (is (not (check s "{\"a\":1}")))))
  (testing "URN base"
    (let [s "{\"$id\":\"urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed\",\"properties\":{\"foo\":{\"$ref\":\"urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed#/$defs/bar\"}},\"$defs\":{\"bar\":{\"type\":\"string\"}}}"]
      (is (check s "{\"foo\":\"x\"}"))
      (is (not (check s "{\"foo\":1}")))))
  (testing "unresolvable reference reached during validation throws"
    (is (thrown? clojure.lang.ExceptionInfo (check "{\"$ref\":\"http://nowhere/x\"}" "1")))
    (is (check "{\"$defs\":{\"x\":{\"$ref\":\"http://nowhere/x\"}}}" "1")
        "references that are never reached are not resolved")))

(deftest dynamic-references
  (let [s "{\"$id\":\"https://example.test/strings\",
            \"$defs\":{\"itemType\":{\"$dynamicAnchor\":\"itemType\",\"type\":\"string\"},
                      \"list\":{\"$id\":\"https://example.test/list\",
                              \"$defs\":{\"itemType\":{\"$dynamicAnchor\":\"itemType\"}},
                              \"type\":\"array\",
                              \"items\":{\"$dynamicRef\":\"#itemType\"}}},
            \"$ref\":\"https://example.test/list\"}"]
    (is (check s "[\"a\",\"b\"]"))
    (is (not (check s "[\"a\",1]"))))
  (testing "without an outer dynamic anchor the local one is used"
    (let [s "{\"$id\":\"https://example.test/list\",
              \"$defs\":{\"itemType\":{\"$dynamicAnchor\":\"itemType\",\"type\":\"integer\"}},
              \"items\":{\"$dynamicRef\":\"#itemType\"}}"]
      (is (check s "[1,2]"))
      (is (not (check s "[\"a\"]")))))
  (testing "a $dynamicRef to a plain anchor behaves like $ref"
    (is (not (check "{\"$defs\":{\"a\":{\"$anchor\":\"a\",\"type\":\"string\"}},\"$dynamicRef\":\"#a\"}" "1")))))

(deftest deep-nesting
  (testing "deep instances and schemas need a large stack, which the CLI provides"
    (let [n 3000
          schema (reduce (fn [acc _] {"items" acc}) {"type" "integer"} (range n))
          inst (reduce (fn [acc _] [acc]) 1 (range n))]
      (is (js/with-large-stack (js/valid? (js/validator schema) inst))))))
