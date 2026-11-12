(ns toml.encoder-test
  (:require [clojure.test :refer [deftest is]]
            [toml.core :as toml]
            [toml.encoder :as e]
            [toml.json :as json]))

(defn- enc [json-text] (e/encode (json/read-tagged json-text)))

(def sample
  "{\"db\":{\"enabled\":{\"type\":\"bool\",\"value\":\"true\"},\"ports\":[{\"type\":\"integer\",\"value\":\"8001\"},{\"type\":\"integer\",\"value\":\"8002\"}]},\"dob\":{\"type\":\"datetime\",\"value\":\"1979-05-27T07:32:00-08:00\"},\"fruit\":[{\"name\":{\"type\":\"string\",\"value\":\"apple\"}},{\"name\":{\"type\":\"string\",\"value\":\"banana\"}}],\"name\":{\"type\":\"string\",\"value\":\"Tom\"}}")

(deftest worked-example
  (is (= "dob = 1979-05-27T07:32:00-08:00\nname = \"Tom\"\n\n[db]\nenabled = true\nports = [8001, 8002]\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n"
         (enc sample))))

(deftest empty-and-nesting
  (is (= "\n" (enc "{}")))
  (is (= "[a]\n\n[a.b]\n" (enc "{\"a\":{\"b\":{}}}")))
  (is (= "x = 1\n\n[a]\n\n[a.b]\n" (enc "{\"x\":{\"type\":\"integer\",\"value\":\"1\"},\"a\":{\"b\":{}}}")))
  (is (= "a = []\n" (enc "{\"a\":[]}")))
  (is (= "a = [{x = 1}, 2]\n"
         (enc "{\"a\":[{\"x\":{\"type\":\"integer\",\"value\":\"1\"}},{\"type\":\"integer\",\"value\":\"2\"}]}"))))

(deftest key-and-string-quoting
  (is (= "\"\" = \"\"\n\"a b\" = \"\\u0000\\u007f\\\"\\\\\\n\\t\\b\\f\\r\u00e9\"\nok-key_1 = 0\n"
         (enc "{\"\":{\"type\":\"string\",\"value\":\"\"},\"a b\":{\"type\":\"string\",\"value\":\"\\u0000\\u007f\\\"\\\\\\n\\t\\b\\f\\r\u00e9\"},\"ok-key_1\":{\"type\":\"integer\",\"value\":\"0\"}}"))))

(deftest arrays-of-tables-versus-inline
  (is (= "a = [{b = [{c = 1}]}, 2]\n"
         (enc "{\"a\":[{\"b\":[{\"c\":{\"type\":\"integer\",\"value\":\"1\"}}]},{\"type\":\"integer\",\"value\":\"2\"}]}"))
      "a mixed array is inline, with its tables inline too")
  (is (= "[[a]]\n\n[[a.b]]\nc = 1\n"
         (enc "{\"a\":[{\"b\":[{\"c\":{\"type\":\"integer\",\"value\":\"1\"}}]}]}"))))
