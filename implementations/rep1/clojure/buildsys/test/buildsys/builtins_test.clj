(ns buildsys.builtins-test
  (:require [buildsys.builtins :as builtins]
            [buildsys.test-util :refer [build-error eval-expr]]
            [clojure.test :refer [deftest is testing are]]))

(deftest thirty-nine-functions
  (is (= 39 (count (builtins/function-names)))))

(deftest strings
  (are [expr result] (= result (eval-expr expr))
    "len(\"héllo\")" "6"                       ; byte length: é is two bytes
    "upper(\"abcé\") == \"ABCé\"" "true"
    "lower(\"ABC\")" "abc"
    "\"[\" ~ trim(\" \\t\\r\\nx y\\n\") ~ \"]\"" "[x y]"
    "replace(\"aaa\", \"aa\", \"b\")" "ba"
    "starts_with(\"abc\", \"\")" "true"
    "ends_with(\"abc\", \"bc\")" "true"
    "contains(\"abc\", \"x\")" "false"
    "substr(\"abcdef\", 1, 3)" "bcd"
    "substr(\"abcdef\", -2, 5)" "ef"
    "\"[\" ~ substr(\"abcdef\", 10, 2) ~ \"]\"" "[]"
    "\"[\" ~ substr(\"abcdef\", 2, -1) ~ \"]\"" "[]"
    "join(split(\"a,,b\", \",\"), \"|\")" "a||b"
    "len(split(\"\", \",\"))" "1"
    "len(split(\"abc\", \"x\"))" "1"
    "join([1, \"a\", 2], \"-\")" "1-a-2"
    "str(true) ~ str(-5) ~ str(\"s\")" "true-5s"
    "int(\"-007\") + int(3)" "-4"
    "dirname(\"a/b/c.txt\") ~ \"|\" ~ basename(\"a/b/c.txt\")" "a/b|c.txt"
    "\"[\" ~ dirname(\"c.txt\") ~ \"]\"" "[]"
    "stem(\"src/a.b.txt\") ~ \"|\" ~ ext(\"src/a.b.txt\")" "a.b|.txt"
    "stem(\"src/.hidden\") ~ \"|\" ~ ext(\"src/.hidden\")" ".hidden|"
    "stem(\"src/x.\") ~ \"|\" ~ ext(\"src/x.\")" "x|."
    "pathjoin(\"out\", \"\", \"a.txt\")" "out/a.txt"
    "pathjoin(\"out/\")" "out/"
    "join(map([\"a\", \"b\"], \"out/%.o\"), \" \")" "out/a.o out/b.o"
    "join(map([\"a\"], \"100%%-%\"), \"\")" "100%-a"))

(deftest string-errors
  (are [expr result] (= result (eval-expr expr))
    "replace(\"a\", \"\", \"b\")" "E_ARG fn replace: empty pattern"
    "split(\"a\", \"\")" "E_ARG fn split: empty separator"
    "int(\" 1\")" "E_ARG fn int: bad integer"
    "int(\"+1\")" "E_ARG fn int: bad integer"
    "int(\"9223372036854775808\")" "E_ARG fn int: bad integer"
    "int(\"-9223372036854775808\")" "-9223372036854775808"
    "join([[1]], \",\")" "E_TYPE fn join element 0: expected str|int, got list"
    "map([1], \"%\")" "E_TYPE fn map element 0: expected str, got int"
    "filter([1], \"\")" "E_ARG fn filter: bad pattern"
    "filter([\"a\", 1], \"*\")" "E_TYPE fn filter element 1: expected str, got int"
    "glob(\"\")" "E_ARG fn glob: bad pattern"
    "pathjoin()" "E_ARITY fn pathjoin: expected 1-8, got 0"
    "upper(1, 2)" "E_ARITY fn upper: expected 1, got 2"
    "upper(1)" "E_TYPE fn upper argument 1: expected str, got int"
    "len(1)" "E_TYPE fn len argument 1: expected str|list, got int"
    "count(\"a\")" "E_TYPE fn count argument 1: expected list, got str"
    "str([1])" "E_TYPE fn str argument 1: expected str|int|bool, got list"
    "nope(undefined)" "E_UNKNOWN_FUNC nope"
    "upper(undefined, 2)" "E_UNKNOWN_VAR undefined"
    "1 |> cost" "E_UNKNOWN_FUNC cost"))

(deftest lists
  (are [expr result] (= result (eval-expr expr))
    "join(sort([3, \"b\", [1], true, 1, \"a\"]), \" \")" "E_TYPE fn join element 0: expected str|int, got bool"
    "len(sort([3, \"b\", [1], true, 1, \"a\"]))" "6"
    "join(uniq([1, 2, 1, 3, 2]), \",\")" "1,2,3"
    "join(reverse([1, 2, 3]), \",\")" "3,2,1"
    "first([7, 8]) ~ \"\"" "E_TYPE operator ~: expected str, got int"
    "str(last([7, 8]))" "8"
    "join(slice([1, 2, 3, 4], 1, 2), \",\")" "2,3"
    "join(slice([1, 2, 3, 4], -2, 9), \",\")" "3,4"
    "has([[1], 2], [1])" "true"
    "has([1], true)" "false"
    "indexof([5, 6, 7], 7)" "2"
    "indexof([5], 9)" "-1"
    "join(range(3), \",\")" "0,1,2"
    "len(range(0))" "0"
    "sum([1, 2, 3])" "6"
    "sum([])" "0"
    "join(flatten([1, [2, [3]], []]), \",\")" "E_TYPE fn join element 2: expected str|int, got list"
    "len(flatten([1, [2, [3]], []]))" "3"
    "len(zip([1, 2, 3], [\"a\"]))" "1"
    "join(filter([\"a.c\", \"b.h\", \"c.c\"], \"*.c\"), \" \")" "a.c c.c"
    "join(reject([\"a.c\", \"b.h\", \"c.c\"], \"*.c\"), \" \")" "b.h"
    "str(is_str(\"a\")) ~ str(is_int(1)) ~ str(is_bool(1)) ~ str(is_list([]))" "truetruefalsetrue"
    "first([])" "E_ARG fn first: empty list"
    "last([])" "E_ARG fn last: empty list"
    "range(-1)" "E_ARG fn range: negative"
    "sum([1, \"a\"])" "E_TYPE fn sum element 1: expected int, got str"))

(deftest glob-function
  (let [files {"main.kiln" "" "src/a.txt" "x" "src/b.md" "x" "out/o.txt" "x" ".kiln-state" "x"}
        run (fn [pat] (build-error (assoc files "main.kiln" (str "abort join(glob(\"" pat "\"), \" \")\n"))))]
    (is (= "E_ABORT src/a.txt" (run "src/*.txt")))
    (testing "generated paths and the state file are never matched"
      (is (= "E_ABORT main.kiln src/a.txt src/b.md" (run "**"))))))
