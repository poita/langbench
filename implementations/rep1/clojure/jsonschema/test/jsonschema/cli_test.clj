(ns jsonschema.cli-test
  (:require [clojure.test :refer [deftest is]]
            [jsonschema.cli :as cli]))

(deftest example-from-the-specification
  (is (= "valid\ninvalid\ninvalid\n"
         (cli/run "{\"schema\": {\"type\": \"integer\", \"minimum\": 1},
                    \"tests\": [{\"description\": \"a positive integer\", \"data\": 3},
                                {\"description\": \"zero\", \"data\": 0},
                                {\"description\": \"a string\", \"data\": \"3\"}]}"))))

(deftest extra-members-and-empty-tests
  (is (= "" (cli/run "{\"schema\": true, \"tests\": [], \"extra\": 1}")))
  (is (= "invalid\n" (cli/run "{\"schema\": false, \"tests\": [{\"description\":\"x\",\"data\":1}] , \"x\":0}"))
      "false rejects everything"))

(deftest remotes
  (is (= "valid\ninvalid\n"
         (cli/run "{\"schema\": {\"$ref\": \"http://example.test/int\"},
                    \"remotes\": {\"http://example.test/int\": {\"type\": \"integer\"}},
                    \"tests\": [{\"description\":\"a\",\"data\":1},{\"description\":\"b\",\"data\":\"x\"}]}"))))

(deftest malformed-requests
  (is (thrown? clojure.lang.ExceptionInfo (cli/run "{")))
  (is (thrown? clojure.lang.ExceptionInfo (cli/run "[]"))))
