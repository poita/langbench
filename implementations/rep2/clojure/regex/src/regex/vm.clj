(ns regex.vm
  "The backtracking virtual machine that executes programs produced by
  regex.compiler.

  Backtracking is explicit (no recursion), so matching depth is limited only
  by memory.  Two growable int stacks are used:

  * the choice stack, four ints per entry `[pc pos trail-top lo]`.  `lo` is -1
    for an ordinary choice point.  For the greedy single-character runs
    (REPCHAR/REPANY/REPSET) one entry stands for a whole range of give-back
    positions: `pos` is the next position to retry and `lo` the lowest one.
  * the trail, two ints per entry `[register old-value]`.  Every write to a
    register is trailed, so abandoning a path undoes exactly the writes that
    path made."
  (:require [regex.charset :as cs]
            [regex.compiler :as c])
  (:import (java.util Arrays)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(deftype Program [code sets ^long nregs ^long ngroups first-set ^boolean nullable ^boolean anchored])

(defn program
  "Builds a Program from a compiled `{:code :sets :nregs}` map."
  [{:keys [code sets nregs]} ngroups first-set nullable anchored]
  (->Program code sets nregs ngroups first-set (boolean nullable) (boolean anchored)))

(defn workspace
  "Allocates the mutable scratch state (stacks and registers) needed to run
  `prog`.  A workspace may be reused for any number of searches with the same
  program but must not be shared between threads."
  ^objects [^Program prog]
  (let [regs (int-array (.nregs prog))]
    (Arrays/fill regs (int -1))
    (doto (object-array 3)
      (aset 0 (int-array 1024))
      (aset 1 (int-array 1024))
      (aset 2 regs))))

(defn result-size
  "Length of the `out` array that `search` fills in for `prog`."
  ^long [^Program prog]
  (+ 2 (* 2 (.ngroups prog))))

(defn- undo!
  "Restores registers from the trail, popping entries down to height `to`."
  [^ints regs ^ints trail ^long from ^long to]
  (loop [tp from]
    (when (> tp to)
      (let [tp (- tp 2)]
        (aset regs (aget trail tp) (aget trail (+ tp 1)))
        (recur tp)))))

(defmacro ^:private next-start
  "Smallest admissible start position >= `from` (and <= `limit`), or -1."
  [from]
  `(long
    (loop [st# (long ~from)]
     (cond
       (> st# ~'limit) -1
       (or ~'nullable
           (and (< st# ~'len)
                (aget ~'first-set (min (int (aget ~'s st#)) 128))))
       st#
       :else (recur (inc st#))))))

(defmacro ^:private go [pc pos]
  `(recur ~pc ~pos ~'start ~'sp ~'tp ~'stack ~'trail))

(defn search
  "Searches subject `s` (a char array, of which the first `len` chars are the
  subject) for the first match of `prog`, trying start positions in order.

  On success returns true and fills `out` (an int array of `result-size`) with
  `[start end gs1 ge1 gs2 ge2 ...]`, where unset groups have -1 positions.
  Returns false when there is no match."
  [^Program prog ^objects ws ^chars s len ^ints out]
  (let [len (long len)
        ^ints code (.code prog)
        ^objects sets (.sets prog)
        ^booleans first-set (.first-set prog)
        nullable (.nullable prog)
        limit (if (.anchored prog) 0 len)
        ^ints regs (aget ws 2)
        ngroups2 (* 2 (.ngroups prog))
        init (next-start 0)]
    (if (neg? init)
      false
      (loop [pc 0 pos init start init sp 0 tp 0
             ^ints stack (aget ws 0) ^ints trail (aget ws 1)]
        (cond
          ;; ---- failure: backtrack ----
          (neg? pc)
          (if (zero? sp)
            (do (undo! regs trail tp 0)
                (let [ns (next-start (inc start))]
                  (if (neg? ns)
                    (do (aset ws 0 stack) (aset ws 1 trail) false)
                    (recur 0 ns ns 0 0 stack trail))))
            (let [base (- sp 4)
                  epc (aget stack base)
                  epos (aget stack (+ base 1))
                  ett (aget stack (+ base 2))
                  elo (aget stack (+ base 3))]
              (undo! regs trail tp ett)
              (if (neg? elo)
                (recur epc epos start base ett stack trail)
                (if (> epos elo)
                  (do (aset stack (+ base 1) (int (dec epos)))
                      (recur epc epos start sp ett stack trail))
                  (recur epc epos start base ett stack trail)))))

          ;; ---- make room for pushes ----
          (or (> (+ sp 8) (alength stack)) (> (+ tp 8) (alength trail)))
          (recur pc pos start sp tp
                 (Arrays/copyOf stack (int (* 2 (alength stack))))
                 (Arrays/copyOf trail (int (* 2 (alength trail)))))

          :else
          (let [b (* pc 4)
                op (aget code b)]
            (case op
              0 (if (and (< pos len) (== (int (aget s pos)) (aget code (+ b 1))))
                  (go (inc pc) (inc pos))
                  (go -1 pos))
              1 (if (< pos len) (go (inc pc) (inc pos)) (go -1 pos))
              2 (if (and (< pos len)
                         (aget ^booleans (aget sets (aget code (+ b 1)))
                               (min (int (aget s pos)) 128)))
                  (go (inc pc) (inc pos))
                  (go -1 pos))
              3 (if (zero? pos) (go (inc pc) pos) (go -1 pos))
              4 (if (== pos len) (go (inc pc) pos) (go -1 pos))
              5 (do (aset stack sp (aget code (+ b 2)))
                    (aset stack (+ sp 1) (int pos))
                    (aset stack (+ sp 2) (int tp))
                    (aset stack (+ sp 3) (int -1))
                    (recur (aget code (+ b 1)) pos start (+ sp 4) tp stack trail))
              6 (go (aget code (+ b 1)) pos)
              7 (let [r (aget code (+ b 1))]
                  (aset trail tp (int r))
                  (aset trail (+ tp 1) (aget regs r))
                  (aset regs r (int pos))
                  (recur (inc pc) pos start sp (+ tp 2) stack trail))
              8 (let [cap (aget code (+ b 1))
                      tmp (aget code (+ b 2))]
                  (aset trail tp (int cap))
                  (aset trail (+ tp 1) (aget regs cap))
                  (aset trail (+ tp 2) (int (inc cap)))
                  (aset trail (+ tp 3) (aget regs (inc cap)))
                  (aset regs cap (aget regs tmp))
                  (aset regs (inc cap) (int pos))
                  (recur (inc pc) pos start sp (+ tp 4) stack trail))
              9 (if (== (aget regs (aget code (+ b 1))) pos)
                  (go (aget code (+ b 2)) pos)
                  (go (inc pc) pos))
              10 (do (aset out 0 (int start))
                     (aset out 1 (int pos))
                     (System/arraycopy regs 0 out 2 ngroups2)
                     (Arrays/fill regs (int -1))
                     (aset ws 0 stack)
                     (aset ws 1 trail)
                     true)
              ;; 11, 12, 13: greedy runs of a single-character atom
              (let [arg (aget code (+ b 1))
                    mn (aget code (+ b 2))
                    mx (aget code (+ b 3))
                    avail (- len pos)
                    lim (if (neg? mx) avail (min (long mx) avail))
                    n (long
                       (case op
                        11 (loop [i 0]
                             (if (and (< i lim) (== (int (aget s (+ pos i))) arg))
                               (recur (inc i)) i))
                        12 lim
                        (let [^booleans t (aget sets arg)]
                          (loop [i 0]
                            (if (and (< i lim) (aget t (min (int (aget s (+ pos i))) 128)))
                              (recur (inc i)) i)))))]
                (cond
                  (< n mn) (go -1 pos)
                  (> n mn) (do (aset stack sp (int (inc pc)))
                               (aset stack (+ sp 1) (int (dec (+ pos n))))
                               (aset stack (+ sp 2) (int tp))
                               (aset stack (+ sp 3) (int (+ pos mn)))
                               (recur (inc pc) (+ pos n) start (+ sp 4) tp stack trail))
                  :else (go (inc pc) (+ pos n)))))))))))
