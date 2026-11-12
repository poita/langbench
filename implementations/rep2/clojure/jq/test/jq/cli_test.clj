(ns jq.cli-test
  "End-to-end tests of the command-line entry point and, when the shared
  conformance suite is present next to the project, of every case in it."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [jq.core :as jq]
            [jq.json :as json]
            [jq.main :as main])
  (:import (java.nio.charset StandardCharsets)))

(defn- cli
  "What the CLI prints for the stdin text `input`, without the process."
  [^String input]
  (let [[filter-text doc-text] (main/split-input (.getBytes input StandardCharsets/UTF_8))
        out (StringBuilder.)]
    (try
      (let [f (jq/compile-filter filter-text)]
        (f (jq/parse-json doc-text)
           (fn [x] (json/write out x) (.append out "\n"))))
      (catch clojure.lang.ExceptionInfo e
        (when (jq/error? e) (.append out "error\n"))))
    (str out)))

(deftest split-input-at-first-newline
  (is (= [".a" "{\"a\":1}\n"] (main/split-input (.getBytes ".a\n{\"a\":1}\n" StandardCharsets/UTF_8))))
  (is (= [".a" ""] (main/split-input (.getBytes ".a" StandardCharsets/UTF_8)))))

(deftest cli-output-contract
  (is (= "1\n2\n" (cli ".[]\n[1,2]")))
  (is (= "1\nerror\n" (cli "1, error, 2\nnull")))
  (is (= "" (cli "empty\nnull")))
  (is (= "{\"a\":[1,\"é\"]}\n" (cli ".\n {\"a\" : [1, \"\\u00e9\"]} \n"))))

(deftest spec-examples
  (is (= "[{\"name\":\"di\",\"age\":52},{\"name\":\"flo\",\"age\":31},{\"name\":\"ann\",\"age\":31},{\"name\":\"cy\",\"age\":30}]\n"
         (cli (str ".users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})\n"
                   "{\"users\":[{\"name\":\"ann\",\"age\":31,\"active\":true},{\"name\":\"bob\",\"age\":45,\"active\":false},{\"name\":\"cy\",\"age\":30,\"active\":true},{\"name\":\"di\",\"age\":52,\"active\":true},{\"name\":\"ed\",\"age\":29,\"active\":true},{\"name\":\"flo\",\"age\":31,\"active\":true}]}"))))
  (is (= "[11,12,21,22]\n{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}\n[{\"b\":1},5]\n1\nerror\n"
         (cli (str "[(1,2) + (10,20)], {a:(1,2), b:(3,4)}, [.[] | .a?], (.[] | .a.b?)\n"
                   "[{\"a\":{\"b\":1}},{\"a\":5},3]")))))

(def ^:private suite-dir (io/file "../problems/jq/tests"))

(deftest conformance-suite
  (if-not (.isDirectory suite-dir)
    (println "conformance suite not found; skipping")
    (doseq [^java.io.File f (sort-by #(.getName ^java.io.File %) (.listFiles suite-dir))
            :when (str/ends-with? (.getName f) ".in")
            ;; the multi-megabyte inputs are exercised by the external runner
            :when (< (.length f) 1000000)]
      (let [expected (slurp (io/file (str/replace (.getPath f) #"\.in$" ".out")))
            norm (fn [s] (str/join "\n" (map str/trimr (str/split-lines s))))]
        (testing (.getName f)
          (is (= (norm expected) (norm (cli (slurp f))))))))))
