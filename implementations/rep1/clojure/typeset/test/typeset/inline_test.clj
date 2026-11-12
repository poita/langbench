(ns typeset.inline-test
  (:require [clojure.test :refer [deftest is testing]]
            [typeset.hlist :as hlist]
            [typeset.inline :as inline]
            [typeset.util :as u]))

(defn- scan* [^String s & {:as opts}]
  (let [cps (u/code-points s)
        n (alength cps)
        lns (int-array n 1)
        cols (int-array (map inc (range n)))
        counter (atom 0)]
    (inline/scan cps lns cols 0 n (merge {:file "document.cdx" :next-note! #(swap! counter inc)} opts))))

(defn- err [s & opts]
  (try (apply scan* s opts) nil
       (catch clojure.lang.ExceptionInfo e (u/error-line (u/input-error e)))))

(defn- text-of [units]
  (apply str (map (fn [x] (case (:k x) :char (char (:c x)) :space \_ :rigid \~ :disc \| :note \#)) units)))

(deftest plain-text-and-whitespace
  (is (= "a_b" (text-of (scan* "a  b"))))
  (is (= "a_b" (text-of (scan* "  a b  "))))
  (is (= "a~b" (text-of (scan* "a\\ b"))) "escaped space is rigid")
  (is (= "a~b" (text-of (scan* "a~b"))))
  (is (= "ab|c" (text-of (scan* "ab\\-c"))))
  (is (= "{a}|" (text-of (scan* "\\{a\\}\\|")))))

(deftest styles-compose
  (let [[x] (scan* "{b|{i|x}}")]
    (is (true? (get-in x [:st :b])))
    (is (true? (get-in x [:st :i]))))
  (let [[x] (scan* "{+|{-|x}}")]
    (is (= [:up :down] (get-in x [:st :ops])))))

(deftest footnotes
  (let [us (scan* "a{n|note {b|x}}b")]
    (is (= [:char :note :char] (map :k us)))
    (is (= 1 (:n (second us))))
    (is (= 6 (count (:units (second us)))))))

(deftest errors
  (is (= "document.cdx:1:3: unknown-inline" (err "ab{z|x}")))
  (is (= "document.cdx:1:3: unknown-inline" (err "ab{b")))
  (is (= "document.cdx:1:1: unclosed-inline" (err "{b|a{i|b}")))
  (is (= "document.cdx:1:3: stray-brace" (err "ab}")))
  (is (= "document.cdx:1:2: bad-escape" (err "a\\q")))
  (is (= "document.cdx:1:2: bad-escape" (err "a\\")))
  (is (= "document.cdx:1:7: nested-footnote" (err "{n|ab {n|c}}")))
  (is (= "document.cdx:1:3: footnote-not-allowed" (err "ab{n|c}" :no-notes? true))))

(deftest unclosed-reports-innermost
  (is (= "document.cdx:1:5: unclosed-inline" (err "{b|a{i|b"))))

(deftest sentence-ends
  (let [su (fn [s] (inline/string-units s))
        ends? (fn [s] (let [us (su s)
                            i (first (keep-indexed (fn [i x] (when (= :space (:k x)) i)) us))]
                        (hlist/sentence-end? us i)))]
    (is (ends? "end. Next"))
    (is (ends? "wow! Next"))
    (is (ends? "(done.) Next"))
    (is (not (ends? "J. Smith")))
    (is (not (ends? "word Next")))
    (is (ends? ". Next") "a period at the very start qualifies")))
