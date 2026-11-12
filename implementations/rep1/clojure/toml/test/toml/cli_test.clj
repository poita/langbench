(ns toml.cli-test
  (:require [clojure.test :refer [deftest is]]
            [toml.cli :as cli])
  (:import (java.nio.charset StandardCharsets)))

(defn- run [^String s] (cli/run (.getBytes s StandardCharsets/UTF_8)))

(deftest decode-mode
  (is (= "{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}\n" (run "decode\na = 1")))
  (is (= "{}\n" (run "decode\n")))
  (is (= "error\n" (run "decode\na = ")))
  (is (= "error\n" (run "decode\na = 1\r")))
  (is (= "error\n" (cli/run (byte-array (map unchecked-byte (concat (.getBytes "decode\n# ") [0xff])))))))

(deftest encode-mode
  (is (= "a = 1\n" (run "encode\n{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}")))
  (is (= "\n" (run "encode\n{}"))))

(deftest round-trip-through-both-modes
  (let [doc "decode\n[a]\nb = 1.5\nc = [1979-05-27, 'x']\n"
        json (clojure.string/trim (run doc))]
    (is (= "[a]\nb = 1.5000000000000000e+00\nc = [1979-05-27, \"x\"]\n" (run (str "encode\n" json))))))
