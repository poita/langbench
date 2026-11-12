(ns textbuffer.motion
  "Cursor movement: `left`, `right`, `up`, `down`, `home` and `end`, with or
  without extending a selection."
  (:require [textbuffer.cursor :as c]
            [textbuffer.document :as doc]
            [textbuffer.position :as p])
  (:import (textbuffer.cursor Cursor)))

(set! *warn-on-reflection* true)

(def directions
  "The movement directions understood by [[move-cursor]]."
  #{:left :right :up :down :home :end})

(defn- move-left ^long [d ^long head]
  (let [l (p/line head) col (p/col head)]
    (cond (pos? col) (p/pos l (dec col))
          (pos? l) (p/pos (dec l) (doc/line-length d (dec l)))
          :else head)))

(defn- move-right ^long [d ^long head]
  (let [l (p/line head) col (p/col head)]
    (cond (< col (doc/line-length d l)) (p/pos l (inc col))
          (< l (dec (doc/line-count d))) (p/pos (inc l) 0)
          :else head)))

(defn- move-up
  "Returns the new `[head goal]`."
  [d ^long head ^long goal]
  (let [l (p/line head)]
    (if (zero? l)
      [p/origin 0]
      [(p/pos (dec l) (min goal (doc/line-length d (dec l)))) goal])))

(defn- move-down
  "Returns the new `[head goal]`."
  [d ^long head ^long goal]
  (let [l (p/line head)
        last-line (dec (doc/line-count d))]
    (if (== l last-line)
      (let [col (doc/line-length d l)]
        [(p/pos l col) col])
      [(p/pos (inc l) (min goal (doc/line-length d (inc l)))) goal])))

(defn move-cursor
  "Moves cursor `cur` in direction `dir` (one of [[directions]]) inside
  document `d`. With `select?` the selection is extended (or started);
  otherwise it is dropped, except that `:left`/`:right` collapse a selection
  to the corresponding end of its range without further movement.

  Only `:up` and `:down` touch the goal column; resetting it after other
  movements is the caller's job (see [[textbuffer.buffer]])."
  [d ^Cursor cur dir select?]
  (let [head (long (.head cur))
        anchor (.anchor cur)
        goal (long (.goal cur))]
    (if (and (not select?) anchor (or (= dir :left) (= dir :right)))
      (c/->Cursor (if (= dir :left) (c/start cur) (c/end cur))
                  nil (.primary cur) goal)
      (let [base (when select? (or anchor head))
            [new-head new-goal]
            (case dir
              :left [(move-left d head) goal]
              :right [(move-right d head) goal]
              :home [(p/pos (p/line head) 0) goal]
              :end [(p/pos (p/line head) (doc/line-length d (p/line head))) goal]
              :up (move-up d head goal)
              :down (move-down d head goal)
              (throw (IllegalArgumentException. (str "unknown direction: " dir))))]
        (c/->Cursor new-head
                    (when (and base (not= (long base) (long new-head))) base)
                    (.primary cur)
                    new-goal)))))
