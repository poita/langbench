(ns regex.compiler
  "Compiles a syntax tree (see regex.parser) into a graph of `Step` objects
  that implement the backtracking semantics of the specification.

  Every step is compiled together with its continuation (`next`), so matching
  needs no allocation: `(.run step subject state i)` tries to match from
  position `i`, calls the rest of the pattern, and returns true as soon as the
  whole pattern has matched. Backtracking is plain return-false-and-try-the-
  next-alternative, and all mutable data lives in one `long[]` *state* array
  created per match attempt, so a compiled pattern is immutable and safe to
  share between threads.

  State layout (G = number of groups):

      [0, 2G)      capture table: start/end of group g at 2(g-1), 2(g-1)+1;
                   -1 means unset
      [2G, 3G)     where the currently open iteration of group g began
      3G           end position of the overall match
      [3G+1, ...)  start positions of the open iteration of each repetition

  Writes to the state array are undone when the path that made them fails, so
  undo cost is proportional to the number of writes."
  (:require [regex.charset :as cs]))

(set! *warn-on-reflection* true)

(definterface Step
  (^boolean run [^String s ^longs st ^long i]))

(definterface Link
  (link [^regex.compiler.Step target]))

;; A forward reference, used to close the loop of an unbounded repetition.
(deftype Fwd [^:unsynchronized-mutable ^regex.compiler.Step target]
  Step
  (run [_ s st i] (.run target s st i))
  Link
  (link [_ t] (set! target t)))

(defn caps-index
  "Index of the start slot of group `g` in the state array."
  ^long [^long g]
  (* 2 (dec g)))

(defn- starts-index ^long [^long groups ^long g] (+ (* 2 groups) (dec g)))
(defn end-index
  "Index of the overall match end in the state array for `groups` groups."
  ^long [^long groups] (* 3 groups))

(defn- alloc-slot!
  "Reserve a fresh slot in the state array; returns its index."
  ^long [{:keys [counter]}]
  (let [n (long @counter)] (vreset! counter (inc n)) n))

(defn state-size
  "Number of longs the state array needs; call after compiling."
  ^long [{:keys [counter]}] (long @counter))

(defn- single-char? [node]
  (case (first node) (:char :any :set) true false))

(defn- char-table
  "Membership table for a single-character node, as a 128-entry boolean array.
  The second element tells whether characters outside ASCII match."
  [node]
  (case (first node)
    :char [(cs/singleton (second node)) (>= (long (int (second node))) cs/size)]
    :any [(cs/full) true]
    :set [(second node) false]))

(defn- compile-char [c ^Step next]
  (let [c (long (int c))]
    (reify Step
      (run [_ s st i]
        (if (and (< i (.length s)) (== c (long (int (.charAt s i)))))
          (.run next s st (unchecked-inc i))
          false)))))

(defn- compile-table [^booleans tbl high? ^Step next]
  (let [high? (boolean high?)]
    (reify Step
      (run [_ s st i]
        (if (< i (.length s))
          (let [c (long (int (.charAt s i)))]
            (if (if (< c 128) (aget tbl c) high?)
              (.run next s st (unchecked-inc i))
              false))
          false)))))

(defn- compile-simple-rep
  "Greedy repetition of a single-character matcher: take as many as allowed,
  then give them back one at a time. Same order of attempts as the generic
  definition, without recursion per iteration."
  [^booleans tbl high? lo hi ^Step next]
  (let [high? (boolean high?)
        lo (long lo)
        hi (long hi)]
    (reify Step
      (run [_ s st i]
        (let [len (.length s)
              limit (if (< (- len i) hi) len (+ i hi))
              top (loop [j i]
                    (if (< j limit)
                      (let [c (long (int (.charAt s j)))]
                        (if (if (< c 128) (aget tbl c) high?)
                          (recur (unchecked-inc j))
                          j))
                      j))
              bottom (+ i lo)]
          (loop [j top]
            (if (< j bottom)
              false
              (if (.run next s st j)
                true
                (recur (unchecked-dec j))))))))))

(declare compile-node)

(defn- iter-end
  "Continuation of an optional iteration: an empty iteration ends the loop
  (continue with `next`), a non-empty one goes on with `rest`."
  [^long slot ^Step next ^Step rest]
  (reify Step
    (run [_ s st i]
      (if (== i (aget st slot))
        (.run next s st i)
        (.run rest s st i)))))

(defn- opt-step
  "Try one optional iteration (`body`), falling back to `next` if it fails."
  [^long slot ^Step body ^Step next]
  (reify Step
    (run [_ s st i]
      (let [old (aget st slot)]
        (aset st slot i)
        (if (.run body s st i)
          true
          (do (aset st slot old)
              (.run next s st i)))))))

(defn- compile-rep [ctx x lo hi next]
  (let [lo (long lo)]
  (cond
    (and hi (zero? (long hi))) next

    (single-char? x)
    (let [[tbl high?] (char-table x)]
      (compile-simple-rep tbl high? lo (if hi (long hi) Long/MAX_VALUE) next))

    :else
    (let [slot (alloc-slot! ctx)
          ;; optional part: (x (x (... )?)?)? with up to hi-lo copies, or an
          ;; unbounded loop
          tail (if hi
                 (loop [k (- (long hi) lo), rest next]
                   (if (zero? k)
                     rest
                     (recur (dec k)
                            (opt-step slot
                                      (compile-node ctx x (iter-end slot next rest))
                                      next))))
                 (let [^regex.compiler.Link fwd (->Fwd nil)
                       loop-step (opt-step slot
                                           (compile-node ctx x (iter-end slot next fwd))
                                           next)]
                   (.link fwd loop-step)
                   loop-step))]
      ;; mandatory iterations (these run even when they match empty)
      (loop [k lo, cur tail]
        (if (zero? k)
          cur
          (recur (dec k) (compile-node ctx x cur))))))))

(defn- compile-group [ctx n x ^Step next]
  (let [groups (long (:groups ctx))
        ci (caps-index n)
        si (starts-index groups n)
        close (reify Step
                (run [_ s st j]
                  (let [os (aget st ci), oe (aget st (inc ci))]
                    (aset st ci (aget st si))
                    (aset st (inc ci) j)
                    (if (.run next s st j)
                      true
                      (do (aset st ci os)
                          (aset st (inc ci) oe)
                          false)))))
        ^Step body (compile-node ctx x close)]
    (reify Step
      (run [_ s st i]
        (let [old (aget st si)]
          (aset st si i)
          (if (.run body s st i)
            true
            (do (aset st si old) false)))))))

(defn- compile-node [ctx node ^Step next]
  (case (first node)
    :char (compile-char (second node) next)
    :any (compile-table (cs/full) true next)
    :set (compile-table (second node) false next)
    :bol (reify Step
           (run [_ s st i] (if (zero? i) (.run next s st i) false)))
    :eol (reify Step
           (run [_ s st i] (if (== i (.length s)) (.run next s st i) false)))
    :seq (reduce (fn [nxt n] (compile-node ctx n nxt)) next (rseq (second node)))
    :alt (let [^objects branches (object-array (map #(compile-node ctx % next) (second node)))
               n (alength branches)]
           (reify Step
             (run [_ s st i]
               (loop [k 0]
                 (if (< k n)
                   (if (.run ^Step (aget branches k) s st i)
                     true
                     (recur (unchecked-inc k)))
                   false)))))
    :group (compile-group ctx (second node) (nth node 2) next)
    :rep (let [[_ x lo hi] node] (compile-rep ctx x lo hi next))))

(defn compile-ast
  "Compile `ast` (a parse tree over `groups` groups). Returns
  `{:step Step, :state-size n}`; `:step` is the entry point, to be run with a
  state array of `n` longs whose capture slots hold -1."
  [ast groups]
  (let [groups (long groups)
        ctx {:groups groups :counter (volatile! (inc (end-index groups)))}
        accept (reify Step
                 (run [_ s st i] (aset st (end-index groups) i) true))
        step (compile-node ctx ast accept)]
    {:step step :state-size (state-size ctx)}))
