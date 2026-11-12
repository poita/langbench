(ns json.generators
  "test.check generators for JSON trees (see json.tree)."
  (:require [clojure.test.check.generators :as gen]
            [json.tree :as tree]))

(def code-point
  "Any Unicode scalar value, biased towards the interesting ranges: ASCII,
  control characters, the BMP edge below/above the surrogates, and
  supplementary characters."
  (gen/frequency
   [[5 (gen/choose 0x20 0x7E)]
    [3 (gen/choose 0 0x1F)]
    [1 (gen/elements [0x22 0x5C 0x2F 0x7F 0x80 0xD7FF 0xE000 0xFFFF 0x2028])]
    [2 (gen/choose 0x80 0xD7FF)]
    [2 (gen/choose 0xE000 0xFFFF)]
    [2 (gen/choose 0x10000 0x10FFFF)]]))

(def json-string
  (gen/fmap (fn [cps] (String. (int-array cps) 0 (count cps)))
            (gen/vector code-point 0 6)))

(def digits (gen/fmap #(apply str %) (gen/vector (gen/choose 0 9) 1 8)))

(def number-lexeme
  "Text of a number in valid RFC 8259 syntax, with non-canonical exponents."
  (gen/let [neg?  gen/boolean
            int   (gen/one-of [(gen/return "0")
                               (gen/fmap (fn [[a b]] (str a b))
                                         (gen/tuple (gen/choose 1 9)
                                                    (gen/fmap #(if (= % "0") "" %) digits)))])
            frac  (gen/one-of [(gen/return "") (gen/fmap #(str "." %) digits)])
            exp   (gen/one-of [(gen/return "")
                               (gen/fmap (fn [[e s d]] (str e s d))
                                         (gen/tuple (gen/elements ["e" "E"])
                                                    (gen/elements ["" "+" "-"])
                                                    digits))])]
    (str (when neg? "-") int frac exp)))

(def scalar
  (gen/one-of [(gen/return nil)
               gen/boolean
               json-string
               (gen/fmap tree/num-node number-lexeme)]))

(def json-tree
  (gen/recursive-gen
   (fn [inner]
     (gen/one-of
      [(gen/vector inner 0 5)
       (gen/fmap tree/obj-node
                 (gen/vector (gen/tuple json-string inner) 0 6))]))
   scalar))
