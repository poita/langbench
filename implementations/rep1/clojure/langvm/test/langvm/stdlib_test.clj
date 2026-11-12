(ns langvm.stdlib-test
  "Built-in functions: examples from SPEC section 15 and properties checked
  with test.check against the Clojure implementations directly."
  (:require [clojure.test :refer [deftest is testing are]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [langvm.lexer :as lexer]
            [langvm.runtime :as rt :refer [vstr str-of]]
            [langvm.stdlib :as stdlib]
            [langvm.test-util :refer [run-main]])
  (:import (langvm.runtime Rec ICaller)
           (java.util ArrayList)))

(defn- call
  "Call built-in `name` directly (no machine)."
  [name & args]
  (apply (stdlib/lookup name) nil args))

(defn- call-ho
  "Call a higher-order built-in with Clojure functions as callbacks."
  [name & args]
  (apply (stdlib/lookup name)
         (reify ICaller (call [_ f xs] (apply f xs)))
         args))

(defn- panic-message [f]
  (try (f) nil (catch clojure.lang.ExceptionInfo e (:langvm/panic (ex-data e)))))

(defn- option [^Rec r]
  (when (zero? (.vi r)) (aget ^objects (.f r) 0)))

(deftest table-is-complete
  (is (= 132 (count stdlib/table)))
  (is (= 132 (count (distinct stdlib/names)))))

(deftest float-printing
  (are [x d expected] (= expected (str-of (call "showFloatAt" x d)))
    1.0 6 "1.000000"
    0.1 6 "0.100000"
    (/ 2.0 3.0) 6 "0.666667"
    -0.0 6 "-0.000000"
    2.5 0 "2"
    3.5 0 "4"
    0.5 0 "0"
    (/ 1.0 3.0) 10 "0.3333333333"
    (+ 0.1 0.2) 17 "0.30000000000000004"
    1e21 2 "1000000000000000000000.00"
    Double/NaN 3 "nan"
    Double/NEGATIVE_INFINITY 3 "-inf"
    2.675 2 "2.67"
    -0.0001 2 "-0.00")
  (is (= "digits out of range" (panic-message #(call "showFloatAt" 1.0 18))))
  (is (= "digits out of range" (panic-message #(call "showFloatAt" 1.0 -1)))))

(deftest parsing
  (are [s expected] (= expected (option (call "parseInt" (vstr s))))
    "42" 42
    "-0042" -42
    "+7" 7
    "9223372036854775807" Long/MAX_VALUE
    "-9223372036854775808" Long/MIN_VALUE
    "9223372036854775808" nil
    "" nil
    "-" nil
    "1_0" nil
    " 1" nil
    "0x10" nil)
  (are [s radix expected] (= expected (option (call "parseIntRadix" (vstr s) radix)))
    "ff" 16 255
    "FF" 16 255
    "-101" 2 -5
    "z" 36 35
    "2" 2 nil
    "g" 16 nil)
  (are [s expected] (= expected (option (call "parseFloat" (vstr s))))
    "12" 12.0
    "12." 12.0
    ".5" 0.5
    "-1.5e3" -1500.0
    "1e999" Double/POSITIVE_INFINITY
    "inf" nil
    "1e" nil
    "." nil
    "1 " nil)
  (is (= "radix out of range" (panic-message #(call "parseIntRadix" (vstr "1") 37)))))

(deftest float-functions
  (is (= 3.0 (call "roundF" 2.5)))
  (is (= -3.0 (call "roundF" -2.5)))
  (is (= "-0.0" (str (call "roundF" -0.4))))
  (is (= "-0.0" (str (call "ceilF" -0.5))))
  (is (= 1.0 (call "minF" Double/NaN 1.0)))
  (is (Double/isNaN (call "maxF" Double/NaN 1.0)))
  (is (= "-0.0" (str (call "minF" -0.0 0.0))))
  (is (= "0.0" (str (call "minF" 0.0 -0.0))))
  (is (= 1 (call "cmpF" Double/NaN 1.0)))
  (is (= -1 (call "cmpF" 1.0 Double/NaN)))
  (is (= 0 (call "cmpF" Double/NaN Double/NaN)))
  (is (= 1.0 (call "fmodF" 7.0 2.0)))
  (is (= "-0.0" (str (call "fmodF" -4.0 2.0))))
  (is (Double/isNaN (call "fmodF" 1.0 0.0)))
  (is (= 1.0 (call "fmodF" 1.0 Double/POSITIVE_INFINITY)))
  (is (= 1024.0 (call "powF" 2.0 10)))
  (is (= 0.25 (call "powF" 2.0 -2)))
  (is (= "negative exponent" (panic-message #(call "powF" 2.0 Long/MIN_VALUE))))
  (is (= -3 (call "truncToInt" -3.9)))
  (is (= "float out of integer range" (panic-message #(call "truncToInt" 1e19))))
  (is (= "float out of integer range" (panic-message #(call "truncToInt" Double/NaN))))
  (is (= 0x7ff8000000000000 (call "floatBits" (call "nanF")))))

(deftest integers
  (is (= 3486784401 (call "powI" 3 20)))
  (is (= 12 (call "gcdI" -84 36)))
  (is (= Long/MIN_VALUE (call "gcdI" Long/MIN_VALUE 0)) "the exact result 2^63 wraps")
  (is (= -4 (call "divFloor" -7 2)))
  (is (= 1 (call "modFloor" -7 2)))
  (is (= -1 (call "modFloor" 7 -2)))
  (is (= "ff -11111111" (str (str-of (call "showIntRadix" 255 16)) " " (str-of (call "showIntRadix" -255 2)))))
  (is (= "-8000000000000000" (str-of (call "showIntRadix" Long/MIN_VALUE 16))))
  (is (= [8 63 3 64 64] [(call "popCount" 255) (call "clz" 1) (call "ctz" 8) (call "clz" 0) (call "ctz" 0)]))
  (is (= "negative exponent" (panic-message #(call "powI" 2 -1))))
  (is (= "radix out of range" (panic-message #(call "showIntRadix" 1 1)))))

(deftest strings
  (is (= "a||b|\nba\n[007] [x--]\n"
         (run-main "print(strJoin(strSplit(\"a,,b,\", \",\"), \"|\")); print(strReplace(\"aaa\", \"aa\", \"b\"));
print(fmt(\"[{}] [{}]\", [padLeft(\"7\", 3, '0'), padRight(\"x\", 3, '-')]));")))
  (is (= "\"tab\\there\\n\" '\\'' '\\u{1}'\n"
         (run-main "print(quoteStr(\"tab\\there\\n\") ++ \" \" ++ quoteChar('\\'') ++ \" \" ++ quoteChar('\\u{1}'));")))
  (is (= ["" "a" ""] (mapv str-of (call "strSplit" (vstr ",a,") (vstr ",")))))
  (is (= ["" "a"] (mapv str-of (call "strSplit" (vstr "aaa") (vstr "aa")))))
  (is (= [""] (mapv str-of (call "strSplit" (vstr "") (vstr ",")))))
  (is (= "empty separator" (panic-message #(call "strSplit" (vstr "a") (vstr "")))))
  (is (= "empty separator" (panic-message #(call "strReplace" (vstr "a") (vstr "") (vstr "b")))))
  (is (= [2 -1 0 5] [(call "strIndexOf" (vstr "héllo") (vstr "l"))
                     (call "strIndexOf" (vstr "héllo") (vstr "z"))
                     (call "strIndexOf" (vstr "héllo") (vstr ""))
                     (call "strLastIndexOf" (vstr "héllo") (vstr ""))]))
  (is (= "wörld" (str-of (call "substr" (vstr "héllo, wörld") 7 12))))
  (is (= "HéLLO" (str-of (call "upper" (vstr "héllo")))))
  (is (= "pad" (str-of (call "trim" (vstr " \t pad\n")))))
  (is (= [-1 0 1] [(call "strCmp" (vstr "abc") (vstr "abd")) (call "strCmp" (vstr "ab") (vstr "ab"))
                   (call "strCmp" (vstr "b") (vstr "ab"))]))
  (is (= "index out of bounds" (panic-message #(call "substr" (vstr "ab") 1 3))))
  (is (= "negative count" (panic-message #(call "strRepeat" (vstr "a") -1))))
  (testing "scalar order is not UTF-16 order"
    (is (= -1 (call "strCmp" (vstr "\uFFFF") (vstr "\uD83D\uDE00"))))
    (is (= 1 (call "cmpC" (int 0x1F600) (int 0xFFFF))))))

(deftest format-strings
  (are [template args expected] (= expected (str-of (call "fmt" (vstr template)
                                                          (doto (ArrayList.) (.addAll (map vstr args))))))
    "{} + {} = {}" ["1" "2" "3"] "1 + 2 = 3"
    "{{{}}}" ["x"] "{x}"
    "100%" [] "100%")
  (are [template args] (= "bad format" (panic-message #(call "fmt" (vstr template)
                                                              (doto (ArrayList.) (.addAll (map vstr args))))))
    "{" []
    "{x}" ["a"]
    "}" []
    "{} {}" ["a"]
    "{}" ["a" "b"]))

(deftest lists-and-maps
  (let [xs (doto (ArrayList.) (.add 3) (.add 1) (.add 2))]
    (is (= [1 2 3] (vec (call-ho "sortBy" xs #(long (compare %1 %2))))))
    (is (= [3 1 2] (vec xs)) "sortBy returns a new list")
    (is (= [6 2 4] (vec (call-ho "listMap" xs #(* 2 %)))))
    (is (= 6 (call-ho "listFold" xs 0 +)))
    (is (= [3 2] (vec (call-ho "listFilter" xs #(> % 1)))))
    (is (= 1 (call "listIndexOf" xs 1)))
    (is (= "empty list" (panic-message #(call "pop" (ArrayList.)))))
    (is (= "index out of bounds" (panic-message #(call "removeAt" xs 3))))
    (is (= 3 (option (call-ho "listFind" xs #(> % 2)))))))

(deftest option-and-result
  (is (= "unwrap of None" (panic-message #(call "unwrap" rt/none))))
  (is (= "unwrap of Err" (panic-message #(call "unwrapOk" (rt/err-of 1)))))
  (is (= "unwrap of Ok" (panic-message #(call "unwrapErr" (rt/ok-of 1)))))
  (is (= 5 (call "unwrapOr" rt/none 5))))

;; ---------------------------------------------------------------------------
;; properties

(def gen-scalar-string
  "Strings of arbitrary Unicode scalar values (including supplementary ones)."
  (gen/fmap (fn [cps] (String. (int-array cps) 0 (count cps)))
            (gen/vector (gen/one-of [(gen/choose 0 0xD7FF) (gen/choose 0xE000 0x10FFFF)
                                     (gen/choose 0 127)])
                        0 20)))

(defspec int-text-round-trip 200
  (prop/for-all [n gen/large-integer]
    (= n (option (call "parseInt" (call "showInt" n))))))

(defspec radix-text-round-trip 200
  (prop/for-all [n gen/large-integer radix (gen/choose 2 36)]
    (= n (option (call "parseIntRadix" (call "showIntRadix" n radix) radix)))))

(defspec float-bits-round-trip 200
  (prop/for-all [bits gen/large-integer]
    (= bits (call "floatBits" (call "floatFromBits" bits)))))

(defspec show-float-at-is-nearest 200
  (prop/for-all [x (gen/double* {:NaN? false :infinite? false})
                 d (gen/choose 0 17)]
    (let [shown (java.math.BigDecimal. (str-of (call "showFloatAt" x d)))
          err (.abs (.subtract shown (java.math.BigDecimal. ^double x)))
          half-unit (.movePointLeft (java.math.BigDecimal. "0.5") (int d))]
      (<= (.compareTo err half-unit) 0))))

(defspec split-join-round-trip 200
  (prop/for-all [s gen-scalar-string
                 sep (gen/such-that seq gen-scalar-string)]
    (= s (str-of (call "strJoin" (call "strSplit" (vstr s) (vstr sep)) (vstr sep))))))

(defspec quote-str-is-a-string-literal 200
  (prop/for-all [s gen-scalar-string]
    (let [toks (lexer/lex [(str-of (call "quoteStr" (vstr s)))])]
      (= [[:str s]] (mapv (fn [[k v]] [k v]) (butlast toks))))))

(defspec chars-round-trip 200
  (prop/for-all [s gen-scalar-string]
    (= s (str-of (call "strOfChars" (call "chars" (vstr s)))))))

(defspec strlen-counts-scalars 200
  (prop/for-all [s gen-scalar-string]
    (= (.codePointCount ^String s 0 (.length ^String s)) (call "strLen" (vstr s)))))

(defspec sort-by-is-sorted-and-stable 100
  (prop/for-all [xs (gen/vector (gen/tuple (gen/choose 0 5) gen/small-integer) 0 40)]
    (let [l (doto (ArrayList.) (.addAll xs))
          sorted (vec (call-ho "sortBy" l #(long (compare (first %1) (first %2)))))]
      (= sorted (vec (sort-by first xs))))))   ; clojure's sort-by is stable too

(defspec pow-i-wraps-like-bigint 100
  (prop/for-all [b gen/large-integer e (gen/choose 0 70)]
    (= (.longValue (.pow (java.math.BigInteger/valueOf b) (int e))) (call "powI" b e))))
