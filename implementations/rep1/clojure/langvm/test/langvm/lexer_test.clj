(ns langvm.lexer-test
  (:require [clojure.test :refer [deftest is testing are]]
            [langvm.diag :as diag]
            [langvm.lexer :as lexer]))

(defn- toks [& lines]
  (mapv (fn [[k v]] [k v]) (butlast (lexer/lex (vec lines)))))

(defn- lex-error [& lines]
  (try (lexer/lex (vec lines)) nil
       (catch clojure.lang.ExceptionInfo e (diag/format-diag e))))

(deftest basic-tokens
  (is (= [["fn" nil] [:ident "main"] ["(" nil] [")" nil] ["{" nil] ["}" nil]]
         (toks "fn main() {}")))
  (is (= [["_" nil] [:ident "_x"] [:ident "X1"]] (toks "_ _x X1")))
  (is (= [["#[" nil] ["::" nil] [".." nil] ["->" nil] ["==" nil] ["!=" nil] ["<=" nil] [">=" nil]
          ["&&" nil] ["||" nil] ["<<" nil] [">>" nil] ["++" nil]]
         (toks "#[ :: .. -> == != <= >= && || << >> ++"))))

(deftest numbers
  (are [src expected] (= [expected] (toks src))
    "42" [:int 42]
    "007" [:int 7]
    "1_000" [:int 1000]
    "0xff" [:int 255]
    "0b101" [:int 5]
    "0x1_F" [:int 31]
    "9223372036854775807" [:int Long/MAX_VALUE]
    "1.5" [:float 1.5]
    "1_.5" [:float 1.5]
    "2e3" [:float 2000.0]
    "1e1_0" [:float 1e10]
    "1.5E-2" [:float 0.015])
  (testing "literals end where their grammar ends"
    (is (= [[:int 1] ["." nil]] (toks "1.")))
    (is (= [[:int 0] [".." nil] [:int 3]] (toks "0..3")))
    (is (= [[:int 1] [:ident "e"]] (toks "1e")))
    (is (= [[:int 1] [:ident "e_5"]] (toks "1e_5")))
    (is (= [[:int 0] [:ident "X1"]] (toks "0X1")))
    (is (= [[:int 123] [:ident "abc"]] (toks "123abc")))))

(deftest strings-and-chars
  (is (= [[:str "a\nb\u00e9"]] (toks "\"a\\nb\\u{E9}\"")))
  (is (= [[:char 39]] (toks "'\\''")))
  (is (= [[:char 0x1F600]] (toks "'\\u{1F600}'")))
  (is (= [[:str ""]] (toks "\"\""))))

(deftest comments
  (is (= [[:ident "a"] [:ident "b"]] (toks "a // x" "/* y /* nested */ z */ b"))))

(deftest positions
  (is (= [1 1] ((juxt diag/pos-line diag/pos-col) (nth (first (lexer/lex ["x"])) 2))))
  (let [ts (lexer/lex ["a" "  b"])]
    (is (= [2 3] ((juxt diag/pos-line diag/pos-col) (nth (second ts) 2))))
    (is (= [2 4] ((juxt diag/pos-line diag/pos-col) (nth (last ts) 2))) "eof is one past the last line")))

(deftest errors
  (are [expected lines] (= expected (apply lex-error lines))
    "error: bad-token at 1:3" ["a $"]
    "error: bad-token at 1:1" ["#"]
    "error: bad-token at 1:1" ["0x"]
    "error: bad-token at 1:1" ["0x_1"]
    "error: bad-token at 1:1" ["0b2"]
    "error: int-range at 1:1" ["9223372036854775808"]
    "error: int-range at 1:3" ["a 0xFFFFFFFFFFFFFFFF"]
    "error: bad-escape at 1:3" ["\"a\\qb\""]
    "error: bad-escape at 1:2" ["'\\q'"]
    "error: bad-escape at 1:2" ["\"\\u{110000}\""]
    "error: bad-escape at 1:2" ["\"\\u{D800}\""]
    "error: unterminated at 1:1" ["\"abc"]
    "error: unterminated at 2:1" ["x" "'ab'"]
    "error: unterminated at 1:3" ["a /* never closed"]
    "error: unterminated at 1:1" ["''"]))

(deftest identifier-length-limit
  (is (nil? (lex-error (apply str (repeat 200 "a")))))
  (is (= "error: bad-token at 1:1" (lex-error (apply str (repeat 201 "a"))))))
