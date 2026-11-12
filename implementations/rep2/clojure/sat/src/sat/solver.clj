(ns sat.solver
  "A MiniSat-style CDCL SAT solver engine.

  Features: two-watched-literal unit propagation, first-UIP conflict analysis
  with local clause minimisation, VSIDS branching (double-precision activities,
  decay 0.95 / 0.999), phase saving, Luby restarts (unit 100 conflicts) and
  periodic deletion of low-activity learnt clauses.

  This namespace is the mutable, array-based engine; most users want the
  friendlier `sat.core` instead.

  Literals are DIMACS integers at the API boundary. Internally variable `k`
  (1-based) becomes index `k-1` and literal `k` / `-k` becomes `2(k-1)` /
  `2(k-1)+1`, so negation is `bit-xor 1`."
  (:require [sat.heap :as heap]
            [sat.luby :as luby])
  (:import (java.util ArrayList Arrays Comparator)))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

;; ---------------------------------------------------------------------------
;; Clauses

(definterface IClause
  (^ints lits [])
  (^boolean isLearnt [])
  (^double activity [])
  (setActivity [^double a])
  (^boolean isDeleted [])
  (markDeleted []))

(deftype Clause [^ints literals
                 ^boolean learnt
                 ^:unsynchronized-mutable ^double act
                 ^:unsynchronized-mutable ^long dead]
  IClause
  (lits [_] literals)
  (isLearnt [_] learnt)
  (activity [_] act)
  (setActivity [_ a] (set! act a))
  (isDeleted [_] (== dead 1))
  (markDeleted [_] (set! dead (long 1))))

;; ---------------------------------------------------------------------------
;; Solver state

;; Indices into the `st` long array of scalar counters.
(def ^:const ^long QHEAD 0)      ; next trail position to propagate
(def ^:const ^long TRAIL-N 1)    ; number of assigned literals
(def ^:const ^long DLEVEL 2)     ; current decision level
(def ^:const ^long OK 3)         ; 0 once the formula is known unsatisfiable
(def ^:const ^long CONFLICTS 4)
(def ^:const ^long DECISIONS 5)
(def ^:const ^long PROPS 6)
(def ^:const ^long RESTARTS 7)
(def ^:const ^long PATH 8)       ; scratch for conflict analysis
(def ^:const ^long OUT-N 9)      ; scratch: size of the learnt clause buffer
(def ^:const ^long BT-LEVEL 10)  ; backjump level computed by analysis
(def ^:const ^long STORED 11)    ; input clauses stored (>= 2 literals)
(def ^:const ^long REDUCTIONS 12)
(def ^:const ^long N-ST 13)

;; Indices into the `dbl` double array.
(def ^:const ^long VAR-INC 0)
(def ^:const ^long CLA-INC 1)
(def ^:const ^long MAX-LEARNTS 2)

(def ^:const ^double VAR-DECAY 0.95)
(def ^:const ^double CLA-DECAY 0.999)
(def ^:const ^long RESTART-UNIT 100)

(deftype Solver [^long nvars
                 ^bytes vals          ; per literal: 1 true, -1 false, 0 unassigned
                 ^bytes phase         ; per variable: saved phase (1 = true)
                 ^bytes seen          ; per variable: scratch for analysis
                 ^ints level          ; per variable: decision level
                 ^objects reason      ; per variable: implying Clause or nil
                 ^ints trail
                 ^ints trail-lim      ; trail size at the start of each level
                 ^objects watches     ; per literal: Clause[] of watchers
                 ^ints wsize          ; per literal: number of live watchers
                 ^doubles act         ; per variable: VSIDS activity
                 ^doubles dbl
                 ^longs st
                 heap
                 ^ArrayList learnts
                 ^ints out            ; learnt-clause buffer
                 ^ints toclear])

(defn new-solver
  "Creates a solver over variables `1..n`."
  ^Solver [^long n]
  (let [act (double-array n)
        h (heap/make-heap n act)
        watches (object-array (* 2 n))
        s (Solver. n
                   (byte-array (* 2 n)) (byte-array n) (byte-array n)
                   (int-array n) (object-array n)
                   (int-array n) (int-array (inc n))
                   watches (int-array (* 2 n))
                   act (double-array [1.0 1.0 2000.0])
                   (long-array N-ST)
                   h (ArrayList.) (int-array (inc n)) (int-array (inc n)))]
    (dotimes [i (* 2 n)] (aset watches i (object-array 4)))
    (dotimes [v n] (heap/insert! h v))
    (aset ^longs (.-st s) OK 1)
    s))

(defn- dlit
  "DIMACS literal -> internal literal."
  ^long [^long k]
  (if (pos? k) (* 2 (dec k)) (inc (* 2 (dec (- k))))))

;; ---------------------------------------------------------------------------
;; Assignment, watches

(defn- enqueue! [^Solver s ^long lit reason]
  (let [^bytes vals (.-vals s) ^longs st (.-st s) ^ints trail (.-trail s)
        v (bit-shift-right lit 1)
        n (aget st TRAIL-N)]
    (aset vals lit (byte 1))
    (aset vals (bit-xor lit 1) (byte -1))
    (aset ^ints (.-level s) v (aget st DLEVEL))
    (aset ^objects (.-reason s) v reason)
    (aset trail n lit)
    (aset st TRAIL-N (inc n))))

(defn- watch! [^Solver s ^long lit c]
  (let [^objects ws (.-watches s) ^ints wsz (.-wsize s)
        n (aget wsz lit)
        ^objects arr (aget ws lit)
        arr (if (== n (alength arr))
              (let [na (Arrays/copyOf arr (int (* 2 n)))]
                (aset ws lit na)
                na)
              arr)]
    (aset arr n c)
    (aset wsz lit (inc n))))

(defn- attach! [^Solver s ^Clause c]
  (let [lits (.lits c)]
    (watch! s (aget lits 0) c)
    (watch! s (aget lits 1) c)))

(defn- propagate
  "Runs unit propagation to fixpoint. Returns a conflicting Clause or nil."
  [^Solver s]
  (let [^bytes vals (.-vals s) ^ints trail (.-trail s) ^objects watches (.-watches s)
        ^ints wsize (.-wsize s) ^longs st (.-st s)]
    (loop []
      (let [qh (aget st QHEAD)]
        (if (< qh (aget st TRAIL-N))
          (let [p (aget trail qh)
                fl (bit-xor p 1)
                ^objects ws (aget watches fl)
                n (aget wsize fl)
                _ (aset st QHEAD (inc qh))
                _ (aset st PROPS (inc (aget st PROPS)))
                confl
                (loop [i 0 j 0]
                  (if (< i n)
                    (let [^Clause c (aget ws i)
                          lits (.lits c)]
                      (when (== (aget lits 0) fl)
                        (aset lits 0 (aget lits 1))
                        (aset lits 1 fl))
                      (let [fst (aget lits 0)]
                        (if (== (aget vals fst) 1)
                          (do (aset ws j c) (recur (inc i) (inc j)))
                          (let [len (alength lits)
                                k (long (loop [k 2]
                                    (cond (>= k len) -1
                                          (not (== (aget vals (aget lits k)) -1)) k
                                          :else (recur (inc k)))))]
                            (if (>= k 0)
                              (let [nl (aget lits k)]
                                (aset lits 1 nl)
                                (aset lits k fl)
                                (watch! s nl c)
                                (recur (inc i) j))
                              (do
                                (aset ws j c)
                                (if (== (aget vals fst) -1)
                                  (do
                                    (loop [i (inc i) j (inc j)]
                                      (if (< i n)
                                        (do (aset ws j (aget ws i)) (recur (inc i) (inc j)))
                                        (aset wsize fl j)))
                                    (aset st QHEAD (aget st TRAIL-N))
                                    c)
                                  (do (enqueue! s fst c)
                                      (recur (inc i) (inc j))))))))))
                    (do (aset wsize fl j) nil)))]
            (if confl confl (recur)))
          nil)))))

(defn- cancel-until! [^Solver s ^long lvl]
  (let [^longs st (.-st s)]
    (when (> (aget st DLEVEL) lvl)
      (let [^bytes vals (.-vals s) ^ints trail (.-trail s) ^bytes phase (.-phase s)
            ^objects reason (.-reason s) h (.-heap s)
            lim (aget ^ints (.-trail-lim s) lvl)]
        (loop [i (dec (aget st TRAIL-N))]
          (when (>= i lim)
            (let [lit (aget trail i)
                  v (bit-shift-right lit 1)]
              (aset vals lit (byte 0))
              (aset vals (bit-xor lit 1) (byte 0))
              (aset phase v (byte (if (zero? (bit-and lit 1)) 1 0)))
              (aset reason v nil)
              (heap/insert! h v)
              (recur (dec i)))))
        (aset st TRAIL-N lim)
        (aset st QHEAD lim)
        (aset st DLEVEL lvl)))))

;; ---------------------------------------------------------------------------
;; Activities

(defn- bump-var! [^Solver s ^long v]
  (let [^doubles act (.-act s) ^doubles dbl (.-dbl s)
        a (+ (aget act v) (aget dbl VAR-INC))]
    (aset act v a)
    (when (> a 1e100)
      (dotimes [i (alength act)] (aset act i (* (aget act i) 1e-100)))
      (aset dbl VAR-INC (* (aget dbl VAR-INC) 1e-100)))
    (heap/increased! (.-heap s) v)))

(defn- bump-clause! [^Solver s ^Clause c]
  (let [^doubles dbl (.-dbl s)
        a (+ (.activity c) (aget dbl CLA-INC))]
    (.setActivity c a)
    (when (> a 1e20)
      (let [^ArrayList ls (.-learnts s)]
        (dotimes [i (.size ls)]
          (let [^Clause l (.get ls i)]
            (.setActivity l (* (.activity l) 1e-20)))))
      (aset dbl CLA-INC (* (aget dbl CLA-INC) 1e-20)))))

(defn- decay-activities! [^Solver s]
  (let [^doubles dbl (.-dbl s)]
    (aset dbl VAR-INC (/ (aget dbl VAR-INC) VAR-DECAY))
    (aset dbl CLA-INC (/ (aget dbl CLA-INC) CLA-DECAY))))

;; ---------------------------------------------------------------------------
;; Conflict analysis

(defn- analyze!
  "First-UIP analysis of `confl`. Leaves the learnt clause in `out[0..OUT-N)`
  (asserting literal first, a literal of the backjump level second) and the
  backjump level in `st[BT-LEVEL]`."
  [^Solver s ^Clause confl]
  (let [^longs st (.-st s) ^bytes seen (.-seen s) ^ints level (.-level s) ^ints trail (.-trail s)
        ^objects reason (.-reason s) ^ints out (.-out s) ^ints toclear (.-toclear s)
        dl (aget st DLEVEL)]
    (aset st PATH 0)
    (aset st OUT-N 1)
    (loop [^Clause confl confl p -1 idx (dec (aget st TRAIL-N))]
      (when (.isLearnt confl) (bump-clause! s confl))
      (let [lits (.lits confl) len (alength lits)]
        (loop [j (if (== p -1) 0 1)]
          (when (< j len)
            (let [q (aget lits j) v (bit-shift-right q 1)]
              (when (and (zero? (aget seen v)) (> (aget level v) 0))
                (bump-var! s v)
                (aset seen v (byte 1))
                (if (>= (aget level v) dl)
                  (aset st PATH (inc (aget st PATH)))
                  (let [n (aget st OUT-N)]
                    (aset out n q)
                    (aset st OUT-N (inc n)))))
              (recur (inc j))))))
      (let [idx (long (loop [i idx]
                  (if (zero? (aget seen (bit-shift-right (aget trail i) 1))) (recur (dec i)) i)))
            p (aget trail idx)
            v (bit-shift-right p 1)]
        (aset seen v (byte 0))
        (aset st PATH (dec (aget st PATH)))
        (if (> (aget st PATH) 0)
          (recur (aget reason v) p (dec idx))
          (aset out 0 (bit-xor p 1)))))
    ;; Local (one-level, non-recursive) minimisation.
    (let [n0 (aget st OUT-N)]
      (System/arraycopy out 0 toclear 0 n0)
      (let [n (long (loop [i 1 j 1]
                (if (< i n0)
                  (let [q (aget out i)
                        ^Clause r (aget reason (bit-shift-right q 1))
                        keep? (or (nil? r)
                                  (let [rl (.lits r) rn (alength rl)]
                                    (loop [k 1]
                                      (cond (>= k rn) false
                                            (let [w (bit-shift-right (aget rl k) 1)]
                                              (and (zero? (aget seen w)) (> (aget level w) 0))) true
                                            :else (recur (inc k))))))]
                    (if keep?
                      (do (aset out j q) (recur (inc i) (inc j)))
                      (recur (inc i) j)))
                  j)))]
        (aset st OUT-N n)
        ;; Backjump level: highest level among out[1..], moved to position 1.
        (if (== n 1)
          (aset st BT-LEVEL 0)
          (let [mi (long (loop [i 2 mi 1]
                     (if (< i n)
                       (recur (inc i)
                              (if (> (aget level (bit-shift-right (aget out i) 1))
                                     (aget level (bit-shift-right (aget out mi) 1)))
                                i mi))
                       mi)))
                t (aget out mi)]
            (aset out mi (aget out 1))
            (aset out 1 t)
            (aset st BT-LEVEL (aget level (bit-shift-right t 1)))))
        (dotimes [i n0]
          (aset seen (bit-shift-right (aget toclear i) 1) (byte 0)))))))

;; ---------------------------------------------------------------------------
;; Clause database reduction

(defn- locked? [^Solver s ^Clause c]
  (let [l0 (aget (.lits c) 0)]
    (and (== (aget ^bytes (.-vals s) l0) 1)
         (identical? (aget ^objects (.-reason s) (bit-shift-right l0 1)) c))))

(defn- reduce-db!
  "Deletes the lower-activity half of the learnt clauses (never binary or
  locked ones) and purges them from the watch lists."
  [^Solver s]
  (let [^ArrayList ls (.-learnts s)
        arr (.toArray ls)
        n (alength arr)
        half (quot n 2)
        cmp (reify Comparator
              (compare [_ a b] (Double/compare (.activity ^Clause a) (.activity ^Clause b))))]
    (Arrays/sort arr cmp)
    (.clear ls)
    (dotimes [i n]
      (let [^Clause c (aget arr i)]
        (if (and (< i half) (> (alength (.lits c)) 2) (not (locked? s c)))
          (.markDeleted c)
          (.add ls c))))
    (let [^objects ws (.-watches s) ^ints wsz (.-wsize s)]
      (dotimes [l (alength ws)]
        (let [^objects a (aget ws l)
              m (aget wsz l)
              j (long (loop [i 0 j 0]
                  (if (< i m)
                    (let [^Clause c (aget a i)]
                      (if (.isDeleted c)
                        (recur (inc i) j)
                        (do (aset a j c) (recur (inc i) (inc j)))))
                    j)))]
          (loop [k j] (when (< k m) (aset a k nil) (recur (inc k))))
          (aset wsz l j))))))

;; ---------------------------------------------------------------------------
;; Search

(defn- pick-branch-lit
  "Returns the next decision literal, or -1 if every variable is assigned."
  ^long [^Solver s]
  (let [h (.-heap s) ^bytes vals (.-vals s) ^bytes phase (.-phase s)]
    (loop []
      (let [v (heap/remove-max! h)]
        (cond (< v 0) -1
              (zero? (aget vals (* 2 v))) (if (== (aget phase v) 1) (* 2 v) (inc (* 2 v)))
              :else (recur))))))

(defn- learn! [^Solver s]
  (let [^longs st (.-st s) ^ints out (.-out s) n (aget st OUT-N)]
    (cancel-until! s (aget st BT-LEVEL))
    (if (== n 1)
      (enqueue! s (aget out 0) nil)
      (let [c (Clause. (Arrays/copyOf out (int n)) true 0.0 0)]
        (.add ^ArrayList (.-learnts s) c)
        (attach! s c)
        (bump-clause! s c)
        (enqueue! s (aget out 0) c)))))

(defn- search!
  "Searches until `budget` conflicts occurred. Returns :sat, :unsat or :restart."
  [^Solver s ^long budget]
  (let [^longs st (.-st s) ^ints lim (.-trail-lim s)]
    (loop [conflicts 0]
      (let [confl (propagate s)]
        (if confl
          (do
            (aset st CONFLICTS (inc (aget st CONFLICTS)))
            (if (zero? (aget st DLEVEL))
              (do (aset st OK 0) :unsat)
              (do (analyze! s confl)
                  (learn! s)
                  (decay-activities! s)
                  (recur (inc conflicts)))))
          (if (>= conflicts budget)
            (do (cancel-until! s 0) :restart)
            (let [lit (pick-branch-lit s)]
              (if (< lit 0)
                :sat
                (let [dl (aget st DLEVEL)]
                  (aset lim dl (aget st TRAIL-N))
                  (aset st DLEVEL (inc dl))
                  (aset st DECISIONS (inc (aget st DECISIONS)))
                  (enqueue! s lit nil)
                  (recur conflicts))))))))))

;; ---------------------------------------------------------------------------
;; Public engine API

(defn add-clause!
  "Adds a clause (a sequence of non-zero DIMACS literals) to the solver, which
  must be at decision level 0 (i.e. before `solve!`). The clause is simplified
  against the root assignment: duplicate literals, tautologies and satisfied
  clauses are dropped, false literals removed, and unit clauses are assigned
  and propagated. Returns false once the formula is known to be unsatisfiable."
  [^Solver s lits]
  (let [^longs st (.-st s) n (.-nvars s) ^bytes vals (.-vals s)]
    (when (== (aget st OK) 1)
      (let [arr (int-array (count lits))]
        (loop [i 0 xs (seq lits)]
          (when xs
            (let [k (long (first xs))]
              (when (or (zero? k) (> (Math/abs k) n))
                (throw (ex-info "literal out of range" {:literal k :num-vars n})))
              (aset arr i (dlit k))
              (recur (inc i) (next xs)))))
        (Arrays/sort arr)
        (let [m (long (loop [i 0 j 0 prev -1]
                  (if (< i (alength arr))
                    (let [lit (aget arr i)]
                      (cond (or (== (aget vals lit) 1) (== lit (bit-xor prev 1)) ) -1
                            (or (== (aget vals lit) -1) (== lit prev)) (recur (inc i) j prev)
                            :else (do (aset arr j lit) (recur (inc i) (inc j) lit))))
                    j)))]
          (cond
            (< m 0) nil                                    ; satisfied / tautology
            (== m 0) (aset st OK 0)                        ; empty clause
            (== m 1) (do (enqueue! s (aget arr 0) nil)
                         (when (propagate s) (aset st OK 0)))
            :else (let [c (Clause. (Arrays/copyOf arr (int m)) false 0.0 0)]
                    (attach! s c)
                    (aset st STORED (inc (aget st STORED))))))))
    (== (aget st OK) 1)))

(defn solve!
  "Runs the search. Returns :sat or :unsat. After :sat, `model` is valid."
  [^Solver s]
  (let [^longs st (.-st s) ^doubles dbl (.-dbl s) ^ArrayList ls (.-learnts s)]
    (if (zero? (aget st OK))
      :unsat
      (do
        (aset dbl MAX-LEARNTS (double (max (quot (aget st STORED) 3) 2000)))
        (loop [i 0]
          (let [r (search! s (* RESTART-UNIT (luby/luby 2 i)))]
            (if (identical? r :restart)
              (do
                (aset st RESTARTS (inc (aget st RESTARTS)))
                (when (>= (.size ls) (aget dbl MAX-LEARNTS))
                  (reduce-db! s)
                  (aset st REDUCTIONS (inc (aget st REDUCTIONS)))
                  (aset dbl MAX-LEARNTS (* (aget dbl MAX-LEARNTS) 1.1)))
                (recur (inc i)))
              r)))))))

(defn model
  "After a :sat result, returns a vector of `nvars` signed DIMACS literals,
  one per variable in increasing order."
  [^Solver s]
  (let [^bytes vals (.-vals s) n (.-nvars s)]
    (loop [v 0 acc (transient [])]
      (if (< v n)
        (recur (inc v) (conj! acc (if (== (aget vals (* 2 v)) 1) (inc v) (- (inc v)))))
        (persistent! acc)))))

(defn stats
  "Search statistics as a map."
  [^Solver s]
  (let [^longs st (.-st s)]
    {:conflicts (aget st CONFLICTS) :decisions (aget st DECISIONS)
     :propagations (aget st PROPS) :restarts (aget st RESTARTS)
     :reductions (aget st REDUCTIONS) :learnts (.size ^ArrayList (.-learnts s))}))
