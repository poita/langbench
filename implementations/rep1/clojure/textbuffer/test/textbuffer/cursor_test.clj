(ns textbuffer.cursor-test
  (:require [clojure.test :refer [deftest is testing]]
            [textbuffer.cursor :as c]
            [textbuffer.position :as p]))

(defn- pt
  ([l col] (pt l col false))
  ([l col primary] (c/->Cursor (p/pos l col) nil primary col)))

(defn- sel
  "Selection from anchor [al ac] to head [hl hc]."
  ([[al ac] [hl hc]] (sel [al ac] [hl hc] false))
  ([[al ac] [hl hc] primary]
   (c/->Cursor (p/pos hl hc) (p/pos al ac) primary hc)))

(defn- summary [cursors]
  (mapv (fn [cur] [(p/->vec (:head cur))
                   (some-> (:anchor cur) p/->vec)
                   (:primary cur)])
        cursors))

(deftest ranges
  (let [fwd (sel [0 1] [0 4])
        back (sel [0 4] [0 1])]
    (is (= [(p/pos 0 1) (p/pos 0 4)] [(c/start fwd) (c/end fwd)]))
    (is (= [(p/pos 0 1) (p/pos 0 4)] [(c/start back) (c/end back)]))
    (is (not (c/backward? fwd)))
    (is (c/backward? back))
    (is (c/selection? fwd))
    (is (not (c/selection? (pt 0 1))))
    (is (= (c/start (pt 2 2)) (c/end (pt 2 2))))))

(deftest constructor-drops-degenerate-selection
  (is (nil? (:anchor (c/cursor (p/pos 1 1) (p/pos 1 1))))))

(deftest normalize-sorts
  (is (= [[[0 1] nil false] [[2 0] nil true]]
         (summary (c/normalize [(pt 2 0 true) (pt 0 1)])))))

(deftest normalize-merges-points
  (is (= [[[1 1] nil true]]
         (summary (c/normalize [(pt 1 1) (pt 1 1 true)])))))

(deftest point-merges-into-selection
  (testing "inside and on both edges"
    (doseq [at [[0 1] [0 3] [0 5]]]
      (is (= [[[0 5] [0 1] false]]
             (summary (c/normalize [(sel [0 1] [0 5]) (pt (first at) (second at))]))))))
  (testing "outside"
    (is (= 2 (count (c/normalize [(sel [0 1] [0 5]) (pt 0 6)]))))))

(deftest selections-merge-only-when-overlapping
  (testing "touching selections stay apart"
    (is (= 2 (count (c/normalize [(sel [0 1] [0 3]) (sel [0 3] [0 5])])))))
  (testing "overlapping selections merge, keeping the first's direction"
    (is (= [[[0 5] [0 1] false]]
           (summary (c/normalize [(sel [0 1] [0 4]) (sel [0 2] [0 5])]))))
    (is (= [[[0 1] [0 5] false]]
           (summary (c/normalize [(sel [0 4] [0 1]) (sel [0 2] [0 5])]))))))

(deftest equal-start-larger-end-first
  (is (= [[[0 6] [0 2] false]]
         (summary (c/normalize [(sel [0 2] [0 3]) (sel [0 2] [0 6])])))))

(deftest merged-cursor-keeps-first-goal
  (let [a (assoc (pt 1 2) :goal 9)
        b (assoc (pt 1 2) :goal 4)]
    (is (= 9 (:goal (first (c/normalize [a b])))))))

(deftest merged-primary
  (is (:primary (first (c/normalize [(pt 1 1) (pt 1 1 true)]))))
  (is (:primary (first (c/normalize [(sel [0 0] [0 5]) (pt 0 2 true)])))))

(deftest chain-merging
  (is (= 1 (count (c/normalize [(sel [0 0] [0 4]) (sel [0 3] [0 7]) (sel [0 6] [0 9]) (pt 0 9)])))))

(deftest goal-columns
  (is (= [3] (mapv :goal (c/reset-goals [(assoc (pt 0 3) :goal 8)])))))
