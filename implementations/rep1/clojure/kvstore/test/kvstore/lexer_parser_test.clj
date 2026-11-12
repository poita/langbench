(ns kvstore.lexer-parser-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [kvstore.bytes :as b]
            [kvstore.lexer :as lexer]
            [kvstore.parser :as parser]))

(defn kind
  "Error kind raised by parsing `line`, or :ok."
  [line]
  (try (parser/parse-line line) :ok
       (catch clojure.lang.ExceptionInfo e (:kind (ex-data e)))))

(deftest tokens
  (is (= [[:word "put"] [:string "a"] [:int "-12"] [:op "<="] [:punct "{"]]
         (lexer/tokenize "  put\t\"a\" -12 <= {")))
  (testing "escapes"
    (is (= [[:string "a\"\\/\b\f\n\r\tA"]] (lexer/tokenize "\"a\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0041\""))))
  (testing "lexical errors"
    (doseq [bad ["007" "-0" "-" "+1" "=" "!" "\"abc" "\"\\x\"" "\"\\u00zz\"" "#" "é" "\"a\tb\""]]
      (is (= :syntax (kind bad)) bad))))

(deftest stage-order
  (is (= :syntax (kind "")) "empty line")
  (is (= :syntax (kind "   ")) "blank line")
  (is (= :syntax (kind "1 \"x\"")))
  (is (= :unknown-command (kind "frobnicate \"\\ud800\"")))
  (is (= :unknown-command (kind "PUT \"a\" 1")))
  (is (= :bad-utf8 (kind "put \"\\ud800\" 1")))
  (is (= :syntax (kind "put 1 \"x\"")))
  (is (= :syntax (kind "get \"a\" \"\\ud800\"")))
  (is (= :syntax (kind "put \"a\" 1 99999999999999999999")))
  (is (= :int-range (kind "put \"a\" 9223372036854775808")))
  (is (= :ok (kind "put \"a\" -9223372036854775808")))
  (is (= :bad-key (kind "put \"\" 1")))
  (is (= :bad-key (kind (str "get \"" (apply str (repeat 129 "x")) "\""))))
  (is (= :ok (kind (str "get \"" (apply str (repeat 128 "x")) "\""))))
  (is (= :ok (kind "put \"\\ud83d\\ude00\" 1"))))

(deftest values
  (is (= {"x" [1 nil true] "y" "z"}
         (:doc (parser/parse-line "put \"a\" {x:[1,null,true],\"y\":\"z\"}"))))
  (is (= "a" (b/from-utf8 (:key (parser/parse-line "put \"a\" 1")))))
  (is (= :syntax (kind "put \"a\" [1,]")))
  (is (= :syntax (kind "put \"a\" {a:1,}")))
  (is (= :dup-field (kind "put \"a\" {x:1,x}")))
  (is (= :dup-field (kind "put \"a\" {x:1,x 2}")))
  (is (= :syntax (kind "put \"a\" nul"))))

(deftest depth-limit
  (let [open (apply str (repeat 32 "["))
        close (apply str (repeat 32 "]"))]
    (is (= :ok (kind (str "put \"a\" " open close))))
    (is (= :depth (kind (str "put \"a\" " open "1" close))))
    (is (= :depth (kind (str "put \"a\" " open "99999999999999999999"))))
    (is (= :depth (kind (str "put \"a\" " open))))
    (is (= :depth (kind (str "put \"a\" " open ")"))))
    (is (= :syntax (kind (str "put \"a\" " open "-"))))
    (is (= :depth (kind (str "put \"a\" " (apply str (repeat 30 "[")) "{x:[[1]],x:1}"))))
    (is (= :dup-field (kind (str "put \"a\" " (apply str (repeat 30 "[")) "{x:1,x:[[1]]}"))))))

(deftest paths
  (is (= [:cmd :unset] [:cmd (:cmd (parser/parse-line "unset \"a\" x . y"))]))
  (is (= ["x" "y"] (:path (parser/parse-line "unset \"a\" x . y"))))
  (is (= :bad-path (kind "unset \"a\" a.b.c.d.e.f.g.h.i.")))
  (is (= :ok (kind "unset \"a\" a.b.c.d.e.f.g.h")))
  (is (= :bad-path (kind (str "unset \"a\" " (apply str (repeat 31 "x")) " ."))))
  (is (= :ok (kind (str "unset \"a\" " (apply str (repeat 30 "x"))))))
  (is (= :bad-path (kind "unset \"a\" aaaaaaaa.bbbbbbbb.cccccccc.dddddddd")))
  (is (= :syntax (kind "unset \"a\" a."))))

(deftest scan-options
  (is (= {:cmd :scan :reverse true :keys true :limit 3}
         (select-keys (parser/parse-line "scan reverse keys limit 3") [:cmd :reverse :keys :limit])))
  (is (= :syntax (kind "scan limit 1 limit 2")))
  (is (= :syntax (kind "scan reverse reverse")))
  (is (= :syntax (kind "scan limit -1")))
  (is (= :syntax (kind "scan limit 2147483648")))
  (is (= :int-range (kind "scan limit 99999999999999999999")))
  (is (= :ok (kind "scan from \"\" to \"zz\" limit 0")))
  (is (= :ok (kind (str "scan from \"" (apply str (repeat 300 "k")) "\""))))
  (is (= :syntax (kind "scan frob"))))

(deftest predicates
  (is (= [:or [:cmp "==" ["a"] 1] [:and [:cmp "<" ["b"] 2] [:exists ["c"]]]]
         (:pred (parser/parse-line "find a == 1 or b < 2 and exists c"))))
  (is (= [:and [:and [:cmp "==" ["a"] 1] [:cmp "==" ["b"] 2]] [:cmp "==" ["c"] 3]]
         (:pred (parser/parse-line "find (a==1 and b==2) and c==3"))))
  (is (= [:not [:missing ["x" "y"]]] (:pred (parser/parse-line "find not(missing x.y)"))))
  (testing "keywords double as field names"
    (is (= [:cmp "==" ["not"] 1] (:pred (parser/parse-line "find not == 1"))))
    (is (= [:cmp "==" ["exists"] 1] (:pred (parser/parse-line "find exists == 1"))))
    (is (= [:cmp "==" ["and"] 1] (:pred (parser/parse-line "find and == 1")))))
  (is (= 5 (:limit (parser/parse-line "find a == 1 limit 5"))))
  (is (= :syntax (kind "find a == 1 b")))
  (is (= :syntax (kind "find a = 1")))
  (is (= :syntax (kind "find a == foo")))
  (is (= :syntax (kind "find")))
  (is (= :syntax (kind "find a == 1 limit")))
  (is (= :ok (kind "find a == [1,2] and b != {x:1}"))))

(deftest simple-commands
  (doseq [c ["begin" "commit" "rollback" "checkpoint" "stat" "indexes"]]
    (is (= :ok (kind c)))
    (is (= :syntax (kind (str c " x")))))
  (is (= :ok (kind "create index a.b")))
  (is (= :syntax (kind "create a")))
  (is (= :syntax (kind "drop")))
  (is (= :ok (kind "drop index a"))))
