(ns sat.heap
  "Indexed binary max-heap of variables ordered by a shared activity array.
  This is the VSIDS decision-order queue: insertion, removal of the maximum
  and re-sifting after an activity increase are all O(log n).")

(set! *warn-on-reflection* true)

(deftype Heap [^ints heap ^ints pos ^doubles act ^ints sz])

(defn make-heap
  "Creates an empty heap able to hold variables 0..n-1, ordered by `act`."
  ^Heap [^long n ^doubles act]
  (let [pos (int-array n)]
    (java.util.Arrays/fill pos -1)
    (->Heap (int-array n) pos act (int-array 1))))

(defn size ^long [^Heap h] (aget ^ints (.-sz h) 0))

(defn empty-heap? [^Heap h] (zero? (size h)))

(defn in-heap? [^Heap h ^long v] (>= (aget ^ints (.-pos h) v) 0))

(defn- sift-up! [^Heap h ^long i0]
  (let [heap ^ints (.-heap h) pos ^ints (.-pos h) act ^doubles (.-act h)
        x (aget heap i0) ax (aget act x)]
    (loop [i i0]
      (let [p (bit-shift-right (dec i) 1)]
        (if (and (pos? i) (> ax (aget act (aget heap p))))
          (let [y (aget heap p)]
            (aset heap i y) (aset pos y i)
            (recur p))
          (do (aset heap i x) (aset pos x i)))))))

(defn- sift-down! [^Heap h ^long i0]
  (let [heap ^ints (.-heap h) pos ^ints (.-pos h) act ^doubles (.-act h)
        n (size h)
        x (aget heap i0) ax (aget act x)]
    (loop [i i0]
      (let [l (inc (* 2 i))]
        (if (< l n)
          (let [r (inc l)
                c (if (and (< r n) (> (aget act (aget heap r)) (aget act (aget heap l)))) r l)
                y (aget heap c)]
            (if (> (aget act y) ax)
              (do (aset heap i y) (aset pos y i) (recur c))
              (do (aset heap i x) (aset pos x i))))
          (do (aset heap i x) (aset pos x i)))))))

(defn insert!
  "Adds variable `v` to the heap unless it is already present."
  [^Heap h ^long v]
  (when-not (in-heap? h v)
    (let [n (size h)]
      (aset ^ints (.-heap h) n (int v))
      (aset ^ints (.-pos h) v (int n))
      (aset ^ints (.-sz h) 0 (int (inc n)))
      (sift-up! h n))))

(defn increased!
  "Restores the heap order after the activity of `v` (which is in the heap) grew."
  [^Heap h ^long v]
  (sift-up! h (aget ^ints (.-pos h) v)))

(defn remove-max!
  "Removes and returns the variable of highest activity. The heap must not be empty."
  ^long [^Heap h]
  (let [heap ^ints (.-heap h) pos ^ints (.-pos h)
        top (aget heap 0)
        n (dec (size h))
        last-v (aget heap n)]
    (aset pos top -1)
    (aset ^ints (.-sz h) 0 (int n))
    (when (pos? n)
      (aset heap 0 last-v)
      (aset pos last-v 0)
      (sift-down! h 0))
    top))
