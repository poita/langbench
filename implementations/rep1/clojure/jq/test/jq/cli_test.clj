(ns jq.cli-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as str]
            [jq.cli :as cli])
  (:import [java.io StringWriter]))

(defn- run [text]
  (let [w (StringWriter.)]
    (cli/process text w)
    (str w)))

(deftest spec-example-1
  (is (= "[{\"name\":\"di\",\"age\":52},{\"name\":\"flo\",\"age\":31},{\"name\":\"ann\",\"age\":31},{\"name\":\"cy\",\"age\":30}]\n"
         (run (str ".users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})\n"
                   "{\"users\":[{\"name\":\"ann\",\"age\":31,\"active\":true},{\"name\":\"bob\",\"age\":45,\"active\":false},"
                   "{\"name\":\"cy\",\"age\":30,\"active\":true},{\"name\":\"di\",\"age\":52,\"active\":true},"
                   "{\"name\":\"ed\",\"age\":29,\"active\":true},{\"name\":\"flo\",\"age\":31,\"active\":true}]}\n")))))

(deftest spec-example-2
  (is (= (str "[11,12,21,22]\n{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}\n"
              "[{\"b\":1},5]\n1\nerror\n")
         (run (str "[(1,2) + (10,20)], {a:(1,2), b:(3,4)}, [.[] | .a?], (.[] | .a.b?)\n"
                   "[{\"a\":{\"b\":1}},{\"a\":5},3]\n")))))

(deftest spec-example-3
  (is (= (str "{\"b\":3,\"a\":2}\n6\n[{\"k\":\"a\",\"v\":2},{\"k\":\"b\",\"v\":3},{\"k\":\"b\",\"v\":1}]\n"
              "[[\"a\",1],[\"b\",2]]\n[\"k\",\"v\"]\n0.75\n")
         (run (str "reduce .[] as $o ({}; . + {($o.k): $o.v}), (map(.v) | add), sort_by(.k, -.v), "
                   "(group_by(.k) | map([.[0].k, length])), (.[0] | keys), (.[2].v / 4)\n"
                   "[{\"k\":\"b\",\"v\":1},{\"k\":\"a\",\"v\":2},{\"k\":\"b\",\"v\":3}]\n")))))

(deftest no-output-and-multiline-document
  (is (= "" (run "empty\n[1,\n 2]\n")))
  (is (= "[1,2]\n" (run ".\n  [1,\n 2]\n\n"))))

(deftest output-stops-at-error
  (is (= "1\nerror\n" (run "1, error, 2\nnull\n"))))
