(ns sat.heap
  "An indexed binary max-heap of variable indices `0..n-1`, ordered by an
  external, mutable activity array. Used by the solver as the VSIDS priority
  queue: insertion, removal of the maximum and key increase are O(log n)."
  (:refer-clojure :exclude [empty?]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(deftype Heap [^ints items   ; heap order -> variable
               ^ints pos     ; variable -> heap index, or -1 when absent
               ^longs size   ; single cell: number of items
               ^doubles act]) ; shared activity array (variable -> activity)

(defn make-heap
  "Creates an empty heap able to hold variables `0..n-1`, ordered by `act`."
  [^long n ^doubles act]
  (let [pos (int-array n)]
    (java.util.Arrays/fill pos (int -1))
    (Heap. (int-array n) pos (long-array 1) act)))

(defn size ^long [^Heap h] (aget ^longs (.-size h) 0))

(defn empty? [^Heap h] (zero? (size h)))

(defn in-heap? [^Heap h ^long v] (>= (aget ^ints (.-pos h) v) 0))

(defn- sift-up! [^Heap h ^long i]
  (let [^ints items (.-items h) ^ints pos (.-pos h) ^doubles act (.-act h)
        x (aget items i)
        ax (aget act x)
        i (loop [i i]
            (if (> i 0)
              (let [p (bit-shift-right (dec i) 1)
                    y (aget items p)]
                (if (> ax (aget act y))
                  (do (aset items i y) (aset pos y i) (recur p))
                  i))
              i))]
    (aset items i (int x))
    (aset pos x (int i))))

(defn- sift-down! [^Heap h ^long i]
  (let [^ints items (.-items h) ^ints pos (.-pos h) ^doubles act (.-act h)
        n (aget ^longs (.-size h) 0)
        x (aget items i)
        ax (aget act x)
        i (loop [i i]
            (let [l (inc (* 2 i))]
              (if (< l n)
                (let [r (inc l)
                      c (if (and (< r n) (> (aget act (aget items r)) (aget act (aget items l)))) r l)
                      y (aget items c)]
                  (if (> (aget act y) ax)
                    (do (aset items i y) (aset pos y i) (recur c))
                    i))
                i)))]
    (aset items i (int x))
    (aset pos x (int i))))

(defn insert!
  "Adds variable `v` to the heap unless it is already present."
  [^Heap h ^long v]
  (when-not (in-heap? h v)
    (let [sz ^longs (.-size h)
          n (aget sz 0)]
      (aset ^ints (.-items h) n v)
      (aset ^ints (.-pos h) v n)
      (aset sz 0 (inc n))
      (sift-up! h n))))

(defn increased!
  "Restores the heap order after the activity of `v` has increased. A no-op
  when `v` is not in the heap."
  [^Heap h ^long v]
  (let [i (aget ^ints (.-pos h) v)]
    (when (>= i 0) (sift-up! h i))))

(defn remove-max!
  "Removes and returns the variable of highest activity, or -1 if empty."
  ^long [^Heap h]
  (let [sz ^longs (.-size h)
        n (aget sz 0)]
    (if (zero? n)
      -1
      (let [^ints items (.-items h) ^ints pos (.-pos h)
            top (aget items 0)
            last-v (aget items (dec n))]
        (aset sz 0 (dec n))
        (aset pos top -1)
        (when (> n 1)
          (aset items 0 last-v)
          (aset pos last-v 0)
          (sift-down! h 0))
        top))))
