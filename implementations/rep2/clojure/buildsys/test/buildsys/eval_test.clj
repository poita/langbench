(ns buildsys.eval-test
  "Expression, built-in function and scoping semantics, observed through
  `abort`, which reports the value of an expression as its message."
  (:require [buildsys.test-util :refer [first-error lines]]
            [clojure.test :refer [deftest is testing]]))

(defn- value
  "The text `expr` evaluates to (via `abort`)."
  [expr]
  (let [err (first-error (str "abort " expr "\n"))]
    (if (.startsWith ^String err "E_ABORT ") (subs err 8) err)))

(deftest arithmetic-and-ordering
  (is (= "-3 1" (value "\"{-7 / 2} {7 % -3}\"")))
  (is (= "E_DIV_ZERO" (value "\"{1 / 0}\"")))
  (is (= "true true true" (value "\"{true < 1} {2 < \"a\"} {[] > \"z\"}\"")))
  (is (= "true false" (value "\"{[1,[2]] == [1,[2]]} {1 == true}\"")))
  (is (= "falsex" (value "\"{false && nope}\" ~ \"x\"")) "short-circuit")
  (is (= "E_TYPE operator +: expected int, got str" (value "\"{\"a\" + [1]}\""))))

(deftest operator-errors
  (is (= "E_TYPE operator ++: expected list, got int" (first-error "let x = 1 ++ [2]\n")))
  (is (= "E_TYPE index: expected int, got str" (first-error "let x = 5[\"a\"]\n")))
  (is (= "E_ARG fn index: out of range" (first-error "let x = [1][1]\n")))
  (is (= "E_UNKNOWN_FUNC nope" (first-error "let x = nope(undefined)\n")))
  (is (= "E_UNKNOWN_VAR undefined" (first-error "let x = upper(undefined, 2)\n")))
  (is (= "E_ARITY fn upper: expected 1, got 2" (first-error "let x = upper(\"a\", \"b\")\n")))
  (is (= "E_ARITY fn pathjoin: expected 1-8, got 0" (first-error "let x = pathjoin()\n")))
  (is (= "E_INTERP list" (first-error "let x = \"{[1]}\"\n"))))

(deftest built-in-functions
  (testing "strings"
    (is (= "AB" (value "upper(\"aB\")")))
    (is (= "a b" (value "trim(\" \\ta b\\n\")")))
    (is (= "bcd|ef||" (value "substr(\"abcdef\", 1, 3) ~ \"|\" ~ substr(\"abcdef\", -2, 5) ~ \"|\" ~ substr(\"abcdef\", 10, 2) ~ \"|\" ~ substr(\"abcdef\", 2, -1)")))
    (is (= "3 1 3" (value "\"{count(split(\"a,,b\", \",\"))} {count(split(\"\", \",\"))} {count(split(\"a,,b\", \",\"))}\"")))
    (is (= "b.c|.txt|a" (value "stem(\"x/b.c.txt\") ~ \"|\" ~ ext(\"a.b.txt\") ~ \"|\" ~ stem(\"a.txt\")")))
    (is (= ".hidden" (value "stem(\"src/.hidden\")")))
    (is (= "out/a.txt" (value "pathjoin(\"out\", \"\", \"a.txt\")")))
    (is (= "100%-a" (value "map([\"a\"], \"100%%-%\")[0]")))
    (is (= "E_ARG fn int: bad integer" (value "\"{int(\"+1\")}\""))))
  (testing "lists"
    (is (= "3 1 -1" (value "\"{sum([1,2])} {indexof([5,6],6)} {indexof([5],7)}\"")))
    (is (= "a,b" (value "join(uniq(sort([\"b\",\"a\",\"b\"])), \",\")")))
    (is (= "2" (value "str(len(zip([1,2,3],[4,5])))")))
    (is (= "4" (value "str(len(flatten([[1,2],3,[4]])))")))
    (is (= "E_ARG fn first: empty list" (value "first([])")))
    (is (= "E_TYPE fn join element 1: expected str|int, got list" (value "join([\"a\", []], \",\")")))
    (is (= "E_ARG fn filter: bad pattern" (value "filter([1], \"\")")))
    (is (= "a.txt" (value "join(filter([\"a.txt\", \"b.md\"], \"*.txt\"), \"\")")))))

(deftest scoping-statements
  (is (= "E_ABORT 2 1"
         (first-error (lines "let x = 1" "when true {" "  let x = 2" "  abort \"{x} {1}\"" "}"))))
  (is (= "E_REDEFINE x" (first-error (lines "let x = 1" "let x = 2"))))
  (is (= "E_SET_UNDEFINED y" (first-error (lines "set y = 1"))))
  (is (= "E_ABORT 5" (first-error (lines "let x = 1" "each i in [1,2] {" "  set x = x + 2" "}" "abort \"{x}\""))))
  (testing "rules capture their defining scope by reference"
    (is (= "E_ABORT 2-b"
           (first-error (lines "let base = 1"
                               "rule r(p, q = \"b\") {" "  abort \"{base}-{q}\"" "}"
                               "set base = 2"
                               "use r(1)"))))
    (is (= "E_RULE_RECURSION r" (first-error (lines "rule r() {" "  use r()" "}" "use r()"))))
    (is (= "E_ARG rule r: unknown argument z" (first-error (lines "rule r(a) {" "}" "use r(1, z = 2)"))))
    (is (= "E_ARITY rule r: expected 1, got 2" (first-error (lines "rule r(a) {" "}" "use r(1, 2)"))))
    (is (= "E_UNKNOWN_RULE zzz" (first-error (lines "use zzz(undefined)"))))))
