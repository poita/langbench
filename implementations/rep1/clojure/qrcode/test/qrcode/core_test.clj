(ns qrcode.core-test
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [qrcode.core :as qr]
            [qrcode.render :as render]))

(defn- fixture [name] (slurp (io/resource name)))

(defn- parse-query [line]
  (let [[ecl mask text] (str/split line #" " 3)]
    [text (keyword (str/lower-case ecl)) (if (= mask "auto") :auto (parse-long mask))]))

(deftest spec-worked-examples
  (doseq [n [1 2 3]]
    (testing (str "example " n)
      (let [[text ecl mask] (parse-query (str/trim (fixture (str "example" n ".in"))))]
        (is (= (fixture (str "example" n ".out"))
               (render/->text (qr/encode text ecl mask))))))))

(deftest auto-matches-explicit-mask
  (let [auto (qr/encode "HELLO WORLD" :m)]
    (is (= 0 (:mask auto)))
    (is (= (qr/rows auto) (qr/rows (qr/encode "HELLO WORLD" :m 0))))))

(deftest result-shape
  (let [sym (qr/encode "héllo" :h 5)]
    (is (= {:version 1, :ecl :h, :mode :byte, :mask 5, :size 21}
           (select-keys sym [:version :ecl :mode :mask :size])))
    (is (= 21 (count (qr/rows sym))))
    (is (every? #(= 21 (count %)) (qr/rows sym)))
    (is (= (qr/rows sym)
           (mapv #(apply str (map {true \# false \.} %)) (qr/matrix sym))))
    (is (qr/dark? sym 0 0))))

(deftest version-boundaries
  (is (= 1 (:version (qr/encode (apply str (repeat 17 "a")) :l 0))))
  (is (= 2 (:version (qr/encode (apply str (repeat 18 "a")) :l 0))))
  (is (= 7 (:version (qr/encode (apply str (repeat 150 "a")) :l 0))))
  (is (= 40 (:version (qr/encode (apply str (repeat 7089 "9")) :l))))
  (is (= 40 (:version (qr/encode (apply str (repeat 1273 "a")) :h 3)))))

(deftest errors
  (is (thrown? clojure.lang.ExceptionInfo (qr/encode "" :l)))
  (is (thrown? clojure.lang.ExceptionInfo (qr/encode "a" :z)))
  (is (thrown? clojure.lang.ExceptionInfo (qr/encode "a" :l 8)))
  (is (thrown? clojure.lang.ExceptionInfo (qr/encode "a" :l :best)))
  (is (thrown? clojure.lang.ExceptionInfo
               (qr/encode (apply str (repeat 7090 "9")) :l))))

(defn- finder-ok? [sym x0 y0]
  (every? true?
          (for [dy (range 7), dx (range 7)]
            (let [d (max (abs (- dx 3)) (abs (- dy 3)))]
              (= (qr/dark? sym (+ x0 dx) (+ y0 dy)) (not= d 2))))))

(defspec symbols-are-well-formed 60
  (prop/for-all [text (gen/not-empty gen/string)
                 ecl (gen/elements [:l :m :q :h])
                 mask (gen/one-of [(gen/return :auto) (gen/choose 0 7)])]
    (let [sym (qr/encode text ecl mask)
          n (:size sym)]
      (and (= n (+ 17 (* 4 (:version sym))))
           (<= 0 (:mask sym) 7)
           (or (= mask :auto) (= mask (:mask sym)))
           (finder-ok? sym 0 0)
           (finder-ok? sym (- n 7) 0)
           (finder-ok? sym 0 (- n 7))
           (qr/dark? sym 8 (- n 8))))))

(defspec encoding-is-deterministic-and-mask-changes-symbol 30
  (prop/for-all [text (gen/not-empty gen/string-alphanumeric)]
    (and (= (qr/rows (qr/encode text :q)) (qr/rows (qr/encode text :q)))
         (not= (qr/rows (qr/encode text :q 0)) (qr/rows (qr/encode text :q 1))))))
