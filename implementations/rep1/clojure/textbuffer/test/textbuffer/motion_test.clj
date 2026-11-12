(ns textbuffer.motion-test
  (:require [clojure.test :refer [deftest is testing]]
            [textbuffer.cursor :as c]
            [textbuffer.document :as doc]
            [textbuffer.motion :as m]
            [textbuffer.position :as p]))

(def d (doc/document ["hello" "" "ab"]))

(defn- mv
  ([dir l col] (mv dir l col false nil))
  ([dir l col select? goal]
   (let [cur (c/->Cursor (p/pos l col) nil true (or goal col))
         r (m/move-cursor d cur dir select?)]
     [(p/->vec (:head r)) (some-> (:anchor r) p/->vec) (:goal r)])))

(deftest horizontal
  (is (= [[0 2] nil 3] (mv :left 0 3)))
  (is (= [[0 5] nil 0] (mv :left 1 0 false 0)))
  (is (= [[0 0] nil 0] (mv :left 0 0)))
  (is (= [[1 0] nil 5] (mv :right 0 5)))
  (is (= [[2 2] nil 2] (mv :right 2 2))))

(deftest line-ends
  (is (= [[0 0] nil 3] (mv :home 0 3)))
  (is (= [[0 5] nil 3] (mv :end 0 3))))

(deftest vertical-goal-column
  (is (= [[1 0] nil 4] (mv :down 0 4 false 4)))
  (is (= [[2 2] nil 4] (mv :down 1 0 false 4)))
  (is (= [[1 0] nil 4] (mv :up 2 2 false 4)))
  (is (= [[0 4] nil 4] (mv :up 1 0 false 4))))

(deftest document-edges
  (is (= [[0 0] nil 0] (mv :up 0 3 false 3)))
  (is (= [[2 2] nil 2] (mv :down 2 0 false 0))))

(deftest selection-extension
  (is (= [[0 3] [0 2] 2] (mv :right 0 2 true nil)))
  (is (= [[0 1] [0 2] 2] (mv :left 0 2 true nil)))
  (testing "returning to the anchor drops the selection"
    (let [cur (c/->Cursor (p/pos 0 3) (p/pos 0 2) true 3)
          r (m/move-cursor d cur :left true)]
      (is (nil? (:anchor r)))
      (is (= (p/pos 0 2) (:head r))))))

(deftest collapsing-selection
  (let [fwd (c/->Cursor (p/pos 0 4) (p/pos 0 1) true 4)
        back (c/->Cursor (p/pos 0 1) (p/pos 0 4) true 1)]
    (is (= [(p/pos 0 1) nil] ((juxt :head :anchor) (m/move-cursor d fwd :left false))))
    (is (= [(p/pos 0 4) nil] ((juxt :head :anchor) (m/move-cursor d back :right false))))
    (testing "up drops the selection and then moves"
      (is (= [(p/pos 1 0) nil] ((juxt :head :anchor) (m/move-cursor d (assoc fwd :anchor (p/pos 2 1) :head (p/pos 2 2)) :up false)))))))
