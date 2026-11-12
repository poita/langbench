(ns ordered-map.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [ordered-map.core :as om]
            [ordered-map.node :as node]))

(def ^:private lmin Long/MIN_VALUE)
(def ^:private lmax Long/MAX_VALUE)

(defn- avl-ok?
  "Checks BST order, AVL balance and cached height/size of every node."
  [m]
  (let [root (.-root ^ordered_map.core.OrderedMap m)]
    (letfn [(check [^ordered_map.node.Node n lo hi]
              (if (nil? n)
                true
                (let [l (.-left n) r (.-right n)]
                  (and (or (nil? lo) (> (.-k n) lo))
                       (or (nil? hi) (< (.-k n) hi))
                       (check l lo (.-k n))
                       (check r (.-k n) hi)
                       (<= (Math/abs (- (node/height l) (node/height r))) 1)
                       (= (.-height n) (inc (max (node/height l) (node/height r))))
                       (= (.-size n) (inc (+ (node/size l) (node/size r))))))))]
      (check root nil nil))))

(deftest empty-map
  (let [m (om/ordered-map)]
    (is (zero? (om/count m)))
    (is (nil? (om/min-key m)))
    (is (nil? (om/max-key m)))
    (is (nil? (om/floor m 0)))
    (is (nil? (om/select m 0)))
    (is (zero? (om/rank m 5)))
    (is (= [] (om/range-keys m lmin lmax)))
    (is (nil? (seq m)))))

(deftest insert-get-delete
  (let [m (-> (om/ordered-map) (om/insert 5 "five") (om/insert 2 "two") (om/insert 5 "FIVE"))]
    (is (= 2 (om/count m)))
    (is (= "FIVE" (om/get m 5)))
    (is (= "FIVE" (m 5)))
    (is (= :nf (om/get m 7 :nf)))
    (is (om/contains? m 2))
    (let [m' (om/delete m 5)]
      (is (= 1 (om/count m')))
      (is (not (om/contains? m' 5)))
      (is (= 2 (om/count m)) "original is unchanged (persistence)")
      (is (identical? m' (om/delete m' 5)) "deleting an absent key is a no-op"))))

(deftest neighbours
  (let [m (om/ordered-map [[10 :a] [20 :b] [30 :c]])]
    (is (= 20 (om/floor m 25)))
    (is (= 30 (om/ceil m 25)))
    (is (= 10 (om/floor m 10)))
    (is (= 10 (om/ceil m 10)))
    (is (= 20 (om/succ m 10)))
    (is (nil? (om/pred m 10)))
    (is (nil? (om/succ m 30)))
    (is (= 1 (om/rank m 20)))
    (is (= 2 (om/rank m 21)))
    (is (= 30 (om/select m 2)))
    (is (nil? (om/select m 3)))
    (is (nil? (om/select m -1)))))

(deftest extreme-keys
  (let [m (om/ordered-map [[lmin :lo] [0 :z] [lmax :hi]])]
    (is (nil? (om/succ m lmax)))
    (is (nil? (om/pred m lmin)))
    (is (= lmin (om/floor m (inc lmin))))
    (is (= lmax (om/ceil m 1)))
    (is (= 0 (om/pred m lmax)) "pred is strict")
    (is (= [lmin 0 lmax] (om/range-keys m lmin lmax)))
    (is (= 2 (om/rank m lmax)))
    (is (= [lmax] (om/range-keys m lmax lmax)))
    (is (= [lmin] (om/range-keys m lmin lmin)))))

(deftest range-bounds
  (let [m (om/ordered-map (map #(vector % %) [1 3 5 7 9]))]
    (is (= [3 5 7] (om/range-keys m 2 8)))
    (is (= [3 5 7] (om/range-keys m 3 7)))
    (is (= [] (om/range-keys m 8 2)))
    (is (= [] (om/range-keys m 4 4)))
    (is (= [1] (om/reduce-keys (fn [acc k] (reduced (conj acc k))) [] m 0 100))
        "reduced stops the traversal")))

(deftest seq-and-print
  (let [m (om/ordered-map [[3 "c"] [1 "a"] [2 "b"]])]
    (is (= [[1 "a"] [2 "b"] [3 "c"]] (map vec (seq m))))
    (is (= "#ordered-map [[1 \"a\"] [2 \"b\"] [3 \"c\"]]" (pr-str m)))))

(deftest sorted-insertion-stays-balanced
  (let [n 100000
        m (reduce #(om/insert %1 %2 nil) (om/ordered-map) (range n))]
    (is (avl-ok? m))
    (is (= n (om/count m)))
    (let [m (reduce om/delete m (range (dec n) (dec (quot n 2)) -1))]
      (is (avl-ok? m))
      (is (= (quot n 2) (om/count m))))))

;; Property: behaviour agrees with clojure.core/sorted-map as a model.

(def ^:private key-gen
  (gen/frequency [[8 (gen/choose -20 20)]
                  [1 (gen/elements [lmin lmax (inc lmin) (dec lmax)])]]))

(def ^:private op-gen
  (gen/one-of [(gen/tuple (gen/return :insert) key-gen gen/small-integer)
               (gen/tuple (gen/return :delete) key-gen)]))

(defn- apply-ops [[m model] [op k v]]
  (case op
    :insert [(om/insert m k v) (assoc model k v)]
    :delete [(om/delete m k) (dissoc model k)]))

(defspec agrees-with-sorted-map 200
  (prop/for-all [ops (gen/vector op-gen 0 120)
                 probes (gen/vector key-gen 1 10)]
    (let [[m model] (reduce apply-ops [(om/ordered-map) (sorted-map)] ops)
          ks (vec (keys model))]
      (and (avl-ok? m)
           (= (count model) (om/count m))
           (= (vec (seq model)) (mapv vec (seq m)))
           (= (first ks) (om/min-key m))
           (= (peek ks) (om/max-key m))
           (every? (fn [p]
                     (and (= (om/get m p) (get model p))
                          (= (ffirst (rsubseq model <= p)) (om/floor m p))
                          (= (ffirst (subseq model >= p)) (om/ceil m p))
                          (= (ffirst (rsubseq model < p)) (om/pred m p))
                          (= (ffirst (subseq model > p)) (om/succ m p))
                          (= (count (filter #(< % p) ks)) (om/rank m p))))
                   probes)
           (every? (fn [i] (= (get ks i) (om/select m i)))
                   (range -1 (+ 2 (count ks))))
           (every? (fn [[lo hi]]
                     (= (vec (filter #(<= lo % hi) ks)) (om/range-keys m lo hi)))
                   (for [a probes b probes] [a b]))))))
