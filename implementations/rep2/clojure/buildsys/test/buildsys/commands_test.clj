(ns buildsys.commands-test
  (:require [buildsys.commands :as cmd]
            [buildsys.errors :as e]
            [buildsys.vfs :as vfs]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]))

(defn- run1
  "Runs command `name` with `args` over a single input file holding `content`."
  [name args content]
  (:output (cmd/run name args ["in"] (vfs/put (vfs/empty-vfs) "in" content))))

(deftest lines
  (is (= [] (cmd/split-lines "")))
  (is (= ["a" "b"] (cmd/split-lines "a\nb\n")))
  (is (= ["a" "b"] (cmd/split-lines "a\nb")))
  (is (= ["a" "" "b"] (cmd/split-lines "a\n\nb\n")))
  (is (= [""] (cmd/split-lines "\n")))
  (is (= ["a\r"] (cmd/split-lines "a\r\n"))))

(defspec join-then-split-round-trips 100
  (prop/for-all [ls (gen/vector (gen/fmap #(apply str %) (gen/vector (gen/elements "ab \r") 0 5)))]
    (= ls (cmd/split-lines (cmd/join-lines ls)))))

(deftest text-commands
  (is (= "A1\n" (run1 "upper" [] "a1\n")))
  (is (= "a\nca\n" (run1 "grep" ["a"] "a\nb\nca")) "grep re-emits lines with newlines")
  (is (= "x\n" (run1 "grep" [""] "x")))
  (is (= "b\nz\n" (run1 "sort_lines" [] "z\nb")))
  (is (= "c\nb\na\n" (run1 "reverse_lines" [] "a\nb\nc\n")))
  (is (= "a\nb\n" (run1 "dedup" [] "a\nb\na\n")))
  (is (= "1: a\n2: b\n" (run1 "number" [] "a\nb\n")))
  (is (= "  a\n  \n" (run1 "indent" [2] "a\n\n")))
  (is (= "<a>" (run1 "wrap" ["<" ">"] "a")))
  (is (= "xbx" (run1 "replace" ["a" "x"] "aba")) "whole-content replace")
  (is (= "" (run1 "copy" [] ""))))

(deftest multi-input-commands
  (let [v (-> (vfs/empty-vfs) (vfs/put "a" "1\n2\n") (vfs/put "b" ""))]
    (is (= "1\n2\n1\n2\n" (:output (cmd/run "concat" [] ["a" "a"] v))))
    (is (= "2 a\n0 b\n2 total\n" (:output (cmd/run "count_lines" [] ["a" "b"] v))))
    (is (= "cbf29ce484222325 b\n" (:output (cmd/run "hash" [] ["b"] v))))))

(deftest preprocess
  (let [v (-> (vfs/empty-vfs)
              (vfs/put "main" "title\n@need part\nend\n")
              (vfs/put "part" "PART\n@need deep\n")
              (vfs/put "deep" "DEEP\n"))
        r (cmd/run "preprocess" [] ["main"] v)]
    (is (= "title\nPART\nDEEP\nend\n" (:output r)))
    (is (= ["deep" "part"] (:deps r)))
    (is (= "kiln-deps 1\nneed deep\nneed part\n" (:depfile r))))
  (testing "failures"
    (let [err (fn [content more]
                (try (cmd/run "preprocess" [] ["m"] (reduce-kv vfs/put (vfs/put (vfs/empty-vfs) "m" content) more))
                     (catch clojure.lang.ExceptionInfo ex (e/render ex))))]
      (is (= "E_NEED_PATH ../x" (err "@need ../x\n" {})))
      (is (= "E_NEED_MISSING gone needed by m" (err "@need gone\n" {})))
      (is (= "E_NEED_CYCLE m" (err "@need a\n" {"a" "@need m\n"})))
      (is (= "@need \n" (:output (cmd/run "preprocess" [] ["m"] (vfs/put (vfs/empty-vfs) "m" "@need \n"))))
          "an empty remainder is not a directive"))))

(deftest canonical-rendering
  (is (= "write(\"a\\\\b\\\"\\n\\t\\r\\x01\\x7fü\")" (cmd/canonical "write" ["a\\b\"\n\t\r\u0001\u007fü"])))
  (is (= "indent(4)" (cmd/canonical "indent" [4])))
  (is (= "wrap(\"<<\", \">>\")" (cmd/canonical "wrap" ["<<" ">>"])))
  (is (= "concat()" (cmd/canonical "concat" []))))

(deftest shape-checks
  (is (thrown-with-msg? clojure.lang.ExceptionInfo #"E_CMD_SHAPE write: expected inputs 0-0, got 1"
                        (cmd/check-shape! "write" 1 1 false)))
  (is (thrown-with-msg? clojure.lang.ExceptionInfo #"E_CMD_SHAPE concat: expected inputs 1-N, got 0"
                        (cmd/check-shape! "concat" 0 1 false)))
  (is (thrown-with-msg? clojure.lang.ExceptionInfo #"E_CMD_SHAPE copy: expected outputs 1, got 2"
                        (cmd/check-shape! "copy" 1 2 false)))
  (is (thrown-with-msg? clojure.lang.ExceptionInfo #"preprocess: depfile required"
                        (cmd/check-shape! "preprocess" 1 1 false)))
  (is (thrown-with-msg? clojure.lang.ExceptionInfo #"copy: depfile not allowed"
                        (cmd/check-shape! "copy" 1 1 true))))
