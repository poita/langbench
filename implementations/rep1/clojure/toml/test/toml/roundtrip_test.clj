(ns toml.roundtrip-test
  "Property tests: for every tagged tree the encoder can be given,
  decode(encode(x)) == x, and the JSON codec round-trips."
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [toml.core :as toml]
            [toml.data :as d]
            [toml.json :as json]
            [toml.number :as num]))

(def gen-text
  (gen/fmap #(apply str %)
            (gen/vector (gen/frequency [[8 gen/char-alphanumeric]
                                        [2 (gen/elements [\" \\ \newline \tab \space \u0000 \u007f \é \€ \- \_ \. \= \[ \#])]
                                        [1 (gen/elements [(str (Character/toChars 0x1F600))])]])
                        0 8)
            ))

(def gen-key (gen/one-of [gen-text (gen/elements ["a" "b" "type" "value" "" "a.b" "key-1"])]))

(def gen-scalar
  (gen/one-of
   [(gen/fmap #(d/scalar :string (apply str %)) (gen/vector (gen/elements (seq "ab\"\\\n\t\u0000 é")) 0 6))
    (gen/fmap #(d/scalar :integer (str %)) gen/large-integer)
    (gen/fmap #(d/scalar :float (num/format-float (double %))) (gen/double* {:NaN? true :infinite? true}))
    (gen/fmap #(d/scalar :bool (str %)) gen/boolean)
    (gen/elements [(d/scalar :datetime "1979-05-27T07:32:00Z")
                   (d/scalar :datetime-local "1979-05-27T07:32:00.25")
                   (d/scalar :date-local "1979-05-27")
                   (d/scalar :time-local "07:32:00")])]))

(defn- gen-node [depth]
  (if (zero? depth)
    gen-scalar
    (gen/frequency
     [[4 gen-scalar]
      [2 (gen/vector (gen-node (dec depth)) 0 3)]
      [2 (gen/map gen-key (gen-node (dec depth)) {:max-elements 3})]])))

(def gen-tree (gen/map gen-key (gen-node 3) {:max-elements 4}))

(defspec toml-round-trip 200
  (prop/for-all [tree gen-tree]
    (= tree (toml/parse-tagged (toml/generate-string tree)))))

(defspec json-round-trip 200
  (prop/for-all [tree gen-tree]
    (= tree (json/read-tagged (json/write-tagged tree)))))

(defspec float-text-round-trips 500
  (prop/for-all [x (gen/double* {:NaN? false})]
    (let [t (num/format-float x)]
      (= (Double/doubleToLongBits x) (Double/doubleToLongBits (num/parse-float-text t))))))
