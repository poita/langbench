(ns sat.solver
  "A MiniSat-style conflict-driven clause-learning (CDCL) SAT solver.

  * unit propagation with two watched literals (and blocking literals);
  * first-UIP conflict analysis with local (non-recursive) minimisation;
  * VSIDS branching with phase saving;
  * Luby restarts;
  * periodic deletion of low-activity learnt clauses.

  Literals are encoded internally as `2*(v-1)` (variable v true) and
  `2*(v-1)+1` (variable v false), so that negation is `bit-xor 1`.  The public
  entry point is [[solve]], which works on DIMACS-style signed integers."
  (:require [sat.clause :as clause]
            [sat.heap :as heap]
            [sat.luby :as luby])
  (:import [sat.clause Clause]
           [sat.heap Heap]
           [java.util ArrayList Arrays]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Literal helpers

(defmacro ^:private lvar [l] `(bit-shift-right ~l 1))
(defmacro ^:private lneg [l] `(bit-xor ~l 1))

(defn- ->lit
  "Converts a DIMACS literal (non-zero signed integer) to the internal code."
  ^long [^long k]
  (if (pos? k) (* 2 (dec k)) (inc (* 2 (dec (- k))))))

;; Truth values stored per literal.
(def ^:private ^:const TRUE 1)
(def ^:private ^:const FALSE -1)

;; Slots of the scalar registers `iv` (longs) and `dv` (doubles).
(def ^:private ^:const I-TRAIL 0)
(def ^:private ^:const I-QHEAD 1)
(def ^:private ^:const I-DL 2)
(def ^:private ^:const I-CONFLICTS 3)
(def ^:private ^:const I-DECISIONS 4)
(def ^:private ^:const I-OUTN 5)
(def ^:private ^:const I-PATHC 6)
(def ^:private ^:const I-STORED 7)
(def ^:private ^:const D-VAR-INC 0)
(def ^:private ^:const D-CLA-INC 1)
(def ^:private ^:const D-MAX-LEARNTS 2)

(deftype Solver [^long n
                 ^bytes values           ; per literal: 1 true, -1 false, 0 unassigned
                 ^ints level             ; per variable
                 ^objects reason         ; per variable: Clause or nil
                 ^ints trail
                 ^ints trail-lim
                 ^doubles activity       ; per variable (VSIDS)
                 ^booleans phase         ; per variable: saved polarity
                 ^bytes seen             ; per variable, scratch for analysis
                 ^objects ws-c           ; per literal: Clause[] of watchers
                 ^objects ws-b           ; per literal: int[] of blocking literals
                 ^ints ws-n              ; per literal: number of watchers
                 ^Heap order             ; decision order
                 ^ArrayList learnts
                 ^ints out               ; scratch: learnt clause under construction
                 ^ints clr               ; scratch: literals whose `seen` flag to clear
                 ^longs iv
                 ^doubles dv])

(defn- make-solver ^Solver [^long n]
  (let [ws-c (object-array (* 2 n))
        ws-b (object-array (* 2 n))
        activity (double-array n)
        order (heap/make-heap n activity)
        dv (double-array 3)]
    (dotimes [l (* 2 n)]
      (aset ws-c l (object-array 4))
      (aset ws-b l (int-array 4)))
    (dotimes [v n] (heap/insert! order v))
    (aset dv D-VAR-INC 1.0)
    (aset dv D-CLA-INC 1.0)
    (->Solver n (byte-array (* 2 n)) (int-array n) (object-array n)
              (int-array (inc n)) (int-array (inc n))
              activity (boolean-array n) (byte-array n)
              ws-c ws-b (int-array (* 2 n))
              order (ArrayList.) (int-array (inc n)) (int-array (inc n))
              (long-array 8) dv)))

;; ---------------------------------------------------------------------------
;; Assignment trail

(defn- decision-level ^long [^Solver s] (aget ^longs (.-iv s) I-DL))

(defn- enqueue!
  "Makes literal `l` true, with the given reason clause (or nil)."
  [^Solver s ^long l reason]
  (let [iv ^longs (.-iv s) values ^bytes (.-values s) v (lvar l) t (aget iv I-TRAIL)]
    (aset values l (byte TRUE))
    (aset values (lneg l) (byte FALSE))
    (aset ^ints (.-level s) v (int (aget iv I-DL)))
    (aset ^objects (.-reason s) v reason)
    (aset ^ints (.-trail s) t (int l))
    (aset iv I-TRAIL (inc t))))

(defn- new-decision-level! [^Solver s]
  (let [iv ^longs (.-iv s) dl (aget iv I-DL)]
    (aset ^ints (.-trail-lim s) dl (int (aget iv I-TRAIL)))
    (aset iv I-DL (inc dl))))

(defn- cancel-until!
  "Undoes all assignments above decision level `lvl`, saving phases."
  [^Solver s ^long lvl]
  (let [iv ^longs (.-iv s)]
    (when (> (aget iv I-DL) lvl)
      (let [values ^bytes (.-values s) trail ^ints (.-trail s) phase ^booleans (.-phase s)
            reason ^objects (.-reason s) order ^Heap (.-order s)
            lim (aget ^ints (.-trail-lim s) lvl)]
        (loop [i (dec (aget iv I-TRAIL))]
          (when (>= i lim)
            (let [l (aget trail i) v (lvar l)]
              (aset values l (byte 0))
              (aset values (lneg l) (byte 0))
              (aset reason v nil)
              (aset phase v (== 0 (bit-and l 1)))
              (heap/insert! order v)
              (recur (dec i)))))
        (aset iv I-TRAIL lim)
        (aset iv I-QHEAD lim)
        (aset iv I-DL lvl)))))

;; ---------------------------------------------------------------------------
;; Watches

(defn- ws-add!
  "Registers clause `c` as watching literal `l`, with blocking literal `b`."
  [^Solver s ^long l ^Clause c ^long b]
  (let [ws-n ^ints (.-ws-n s)
        n (aget ws-n l)
        cs (aget ^objects (.-ws-c s) l)
        bs (aget ^objects (.-ws-b s) l)]
    (if (== n (alength ^objects cs))
      (let [cs2 (Arrays/copyOf ^objects cs (* 2 n))
            bs2 (Arrays/copyOf ^ints bs (* 2 n))]
        (aset ^objects cs2 n c) (aset ^ints bs2 n (int b))
        (aset ^objects (.-ws-c s) l cs2)
        (aset ^objects (.-ws-b s) l bs2))
      (do (aset ^objects cs n c) (aset ^ints bs n (int b))))
    (aset ws-n l (int (inc n)))))

(defn- attach! [^Solver s ^Clause c]
  (let [lits ^ints (.-lits c)]
    (ws-add! s (aget lits 0) c (aget lits 1))
    (ws-add! s (aget lits 1) c (aget lits 0))))

;; ---------------------------------------------------------------------------
;; Unit propagation

(defn- visit-watchers!
  "Processes the watchers of the literal that just became false because `p`
  was made true.  Returns a conflicting clause or nil."
  [^Solver s ^long p]
  (let [fl (lneg p)
        values ^bytes (.-values s)
        cs ^objects (aget ^objects (.-ws-c s) fl)
        bs ^ints (aget ^objects (.-ws-b s) fl)
        ws-n ^ints (.-ws-n s)
        n (aget ws-n fl)]
    (loop [i 0 j 0]
      (if (< i n)
        (let [b (aget bs i)]
          (if (== (aget values b) TRUE)
            (do (aset cs j (aget cs i)) (aset bs j b)
                (recur (inc i) (inc j)))
            (let [c ^Clause (aget cs i)
                  lits ^ints (.-lits c)]
              (when (== (aget lits 0) fl)
                (aset lits 0 (aget lits 1))
                (aset lits 1 fl))
              (let [fst (aget lits 0)]
                (if (and (not (== fst b)) (== (aget values fst) TRUE))
                  (do (aset cs j c) (aset bs j fst)
                      (recur (inc i) (inc j)))
                  (let [len (alength lits)
                        k (loop [k 2]
                            (cond (>= k len) -1
                                  (not (== (aget values (aget lits k)) FALSE)) k
                                  :else (recur (inc k))))]
                    (if (>= k 0)
                      (let [nw (aget lits k)]
                        (aset lits 1 nw)
                        (aset lits k fl)
                        (ws-add! s nw c fst)
                        (recur (inc i) j))
                      (do
                        (aset cs j c) (aset bs j fst)
                        (if (== (aget values fst) FALSE)
                          ;; conflict: keep the unprocessed watchers
                          (let [j (loop [i (inc i) j (inc j)]
                                    (if (< i n)
                                      (do (aset cs j (aget cs i))
                                          (aset bs j (aget bs i))
                                          (recur (inc i) (inc j)))
                                      j))]
                            (aset ws-n fl (int j))
                            c)
                          (do (enqueue! s fst c)
                              (recur (inc i) (inc j)))))))))))) 
        (do (aset ws-n fl (int j)) nil)))))

(defn- propagate!
  "Propagates all queued assignments.  Returns a conflicting clause or nil."
  [^Solver s]
  (let [iv ^longs (.-iv s) trail ^ints (.-trail s)]
    (loop []
      (let [q (aget iv I-QHEAD)]
        (if (< q (aget iv I-TRAIL))
          (let [p (aget trail q)]
            (aset iv I-QHEAD (inc q))
            (if-let [confl (visit-watchers! s p)]
              (do (aset iv I-QHEAD (aget iv I-TRAIL)) confl)
              (recur)))
          nil)))))

;; ---------------------------------------------------------------------------
;; VSIDS activities

(defn- bump-var! [^Solver s ^long v]
  (let [act ^doubles (.-activity s) dv ^doubles (.-dv s)
        a (+ (aget act v) (aget dv D-VAR-INC))]
    (aset act v a)
    (when (> a 1e100)
      (dotimes [i (alength act)] (aset act i (* (aget act i) 1e-100)))
      (aset dv D-VAR-INC (* (aget dv D-VAR-INC) 1e-100)))
    (when (heap/in-heap? ^Heap (.-order s) v)
      (heap/increased! ^Heap (.-order s) v))))

(defn- bump-clause! [^Solver s ^Clause c]
  (let [dv ^doubles (.-dv s)
        a (+ (.activity c) (aget dv D-CLA-INC))]
    (.setActivity c a)
    (when (> a 1e20)
      (let [ls ^ArrayList (.-learnts s)]
        (dotimes [i (.size ls)]
          (let [^Clause l (.get ls i)]
            (.setActivity l (* (.activity l) 1e-20)))))
      (aset dv D-CLA-INC (* (aget dv D-CLA-INC) 1e-20)))))

(defn- decay-activities! [^Solver s]
  (let [dv ^doubles (.-dv s)]
    (aset dv D-VAR-INC (/ (aget dv D-VAR-INC) 0.95))
    (aset dv D-CLA-INC (/ (aget dv D-CLA-INC) 0.999))))

;; ---------------------------------------------------------------------------
;; Conflict analysis

(defn- analyze!
  "First-UIP analysis of `confl0`.  Leaves the (minimised) learnt clause in
  `^ints (.-out s)` with the asserting literal first and its length in the OUTN
  register; returns the backjump level."
  ^long [^Solver s ^Clause confl0]
  (let [iv ^longs (.-iv s) seen ^bytes (.-seen s) level ^ints (.-level s) trail ^ints (.-trail s)
        reason ^objects (.-reason s) out ^ints (.-out s) clr ^ints (.-clr s)
        dl (aget iv I-DL)]
    (aset iv I-OUTN 1)
    (aset iv I-PATHC 0)
    ;; Walk the trail backwards resolving on current-level literals.
    (loop [confl confl0 idx (dec (aget iv I-TRAIL)) p -1]
      (when (.-learnt ^Clause confl) (bump-clause! s confl))
      (let [lits ^ints (.-lits ^Clause confl)]
        (loop [j (if (== p -1) 0 1)]
          (when (< j (alength lits))
            (let [q (aget lits j) v (lvar q)]
              (when (and (zero? (aget seen v)) (pos? (aget level v)))
                (bump-var! s v)
                (aset seen v (byte 1))
                (if (>= (aget level v) dl)
                  (aset iv I-PATHC (inc (aget iv I-PATHC)))
                  (let [o (aget iv I-OUTN)]
                    (aset out o (int q))
                    (aset iv I-OUTN (inc o))))))
            (recur (inc j)))))
      (let [idx (long (loop [i idx] (if (zero? (aget seen (lvar (aget trail i)))) (recur (dec i)) i)))
            p (aget trail idx)
            v (lvar p)
            pc (dec (aget iv I-PATHC))]
        (aset seen v (byte 0))
        (aset iv I-PATHC pc)
        (if (pos? pc)
          (recur (aget reason v) (dec idx) p)
          (aset out 0 (int (lneg p))))))
    ;; Local minimisation: drop a literal whose reason is covered by the clause.
    (let [n (aget iv I-OUTN)]
      (System/arraycopy out 0 clr 0 n)
      (let [m (loop [i 1 j 1]
                (if (< i n)
                  (let [q (aget out i) v (lvar q) r (aget reason v)
                        keep? (or (nil? r)
                                  (let [rl ^ints (.-lits ^Clause r)]
                                    (loop [k 1]
                                      (cond (>= k (alength rl)) false
                                            (let [u (lvar (aget rl k))]
                                              (and (zero? (aget seen u)) (pos? (aget level u)))) true
                                            :else (recur (inc k))))))]
                    (if keep?
                      (do (aset out j (int q)) (recur (inc i) (inc j)))
                      (recur (inc i) j)))
                  j))]
        (dotimes [i n] (aset seen (lvar (aget clr i)) (byte 0)))
        (aset iv I-OUTN (long m))
        ;; Backjump level: highest level among the other literals.
        (if (== m 1)
          0
          (let [best (loop [i 2 best 1]
                       (if (< i m)
                         (recur (inc i)
                                (if (> (aget level (lvar (aget out i))) (aget level (lvar (aget out best))))
                                  i best))
                         best))
                t (aget out best)]
            (aset out best (aget out 1))
            (aset out 1 t)
            (aget level (lvar t))))))))

(defn- learn!
  "Backjumps to `bt` and asserts the clause held in the scratch buffer."
  [^Solver s ^long bt]
  (let [iv ^longs (.-iv s) m (aget iv I-OUTN) out ^ints (.-out s)]
    (if (== m 1)
      (do (cancel-until! s 0)
          (enqueue! s (aget out 0) nil))
      (let [c (clause/make-clause (Arrays/copyOf out (int m)) true)]
        (.add ^ArrayList (.-learnts s) c)
        (attach! s c)
        (bump-clause! s c)
        (cancel-until! s bt)
        (enqueue! s (aget out 0) c)))))

;; ---------------------------------------------------------------------------
;; Learnt clause database reduction

(defn- reduce-db!
  "Deletes the lower-activity half of the learnt clauses (never binary ones).
  Must be called at decision level 0."
  [^Solver s]
  (let [ls ^ArrayList (.-learnts s)
        sorted (vec (sort-by #(.activity ^Clause %) (vec ls)))
        half (quot (count sorted) 2)]
    (.clear ls)
    (doseq [[i ^Clause c] (map-indexed vector sorted)]
      (if (and (< i half) (> (alength ^ints (.-lits c)) 2))
        (.markDead c)
        (.add ls c)))
    ;; drop dead clauses from every watch list
    (dotimes [l (* 2 (.-n s))]
      (let [cs ^objects (aget ^objects (.-ws-c s) l)
            bs ^ints (aget ^objects (.-ws-b s) l)
            n (aget ^ints (.-ws-n s) l)
            j (loop [i 0 j 0]
                (if (< i n)
                  (let [^Clause c (aget cs i)]
                    (if (.dead c)
                      (recur (inc i) j)
                      (do (aset cs j c) (aset bs j (aget bs i))
                          (recur (inc i) (inc j)))))
                  j))]
        (dotimes [k (- n j)] (aset cs (+ j k) nil))
        (aset ^ints (.-ws-n s) l (int j))))))

;; ---------------------------------------------------------------------------
;; Search

(defn- pick-branch-lit
  "Returns the decision literal for the unassigned variable of highest
  activity, or -1 when all variables are assigned."
  ^long [^Solver s]
  (let [order ^Heap (.-order s) values ^bytes (.-values s)]
    (loop []
      (if (heap/empty-heap? order)
        -1
        (let [v (heap/remove-max! order)]
          (if (zero? (aget values (* 2 v)))
            (if (aget ^booleans (.-phase s) v) (* 2 v) (inc (* 2 v)))
            (recur)))))))

(defn- search!
  "Runs CDCL until a model (:sat), a refutation (:unsat) or `nof-conflicts`
  conflicts (:restart, after backtracking to the root)."
  [^Solver s ^long nof-conflicts]
  (let [iv ^longs (.-iv s)]
    (loop [conflict-c 0]
      (if-let [confl (propagate! s)]
        (do (aset iv I-CONFLICTS (inc (aget iv I-CONFLICTS)))
            (if (zero? (aget iv I-DL))
              :unsat
              (let [bt (analyze! s confl)]
                (learn! s bt)
                (decay-activities! s)
                (recur (inc conflict-c)))))
        (if (>= conflict-c nof-conflicts)
          (do (cancel-until! s 0) :restart)
          (let [l (pick-branch-lit s)]
            (if (neg? l)
              :sat
              (do (aset iv I-DECISIONS (inc (aget iv I-DECISIONS)))
                  (new-decision-level! s)
                  (enqueue! s l nil)
                  (recur conflict-c)))))))))

;; ---------------------------------------------------------------------------
;; Adding input clauses

(defn- add-clause!
  "Adds an input clause (a seq of DIMACS literals), simplified at the root.
  Returns false when the formula became trivially unsatisfiable."
  [^Solver s lits]
  (let [codes (distinct (map ->lit lits))
        present (set codes)
        values ^bytes (.-values s)]
    (cond
      ;; tautology, or already satisfied at the root
      (or (some #(contains? present (lneg (long %))) codes)
          (some #(== (aget values (long %)) TRUE) codes))
      true

      :else
      (let [ls (filterv #(not (== (aget values (long %)) FALSE)) codes)]
        (case (count ls)
          0 false
          1 (do (enqueue! s (first ls) nil)
                (nil? (propagate! s)))
          (let [c (clause/make-clause (int-array ls) false)]
            (attach! s c)
            (aset ^longs (.-iv s) I-STORED (inc (aget ^longs (.-iv s) I-STORED)))
            true))))))

(defn- extract-model [^Solver s]
  (let [values ^bytes (.-values s)]
    (mapv (fn [^long v] (if (== (aget values (* 2 v)) TRUE) (inc v) (- (inc v))))
          (range (.-n s)))))

;; ---------------------------------------------------------------------------
;; Public API

(defn solve
  "Decides satisfiability of a CNF formula.

  `num-vars` is the number of variables; `clauses` is a sequence of clauses,
  each a sequence of non-zero integers in DIMACS convention (`k` is variable k
  true, `-k` false, with 1 <= |k| <= num-vars).

  Returns `{:status :sat, :model m, :conflicts n, :decisions n}` where `m` is a
  vector with one signed literal per variable in order, or
  `{:status :unsat, :conflicts n, :decisions n}`."
  [num-vars clauses]
  (let [n (long num-vars)
        ^Solver s (make-solver n)
        iv ^longs (.-iv s)
        ok (loop [cs (seq clauses)]
             (if cs
               (let [c (first cs)]
                 (doseq [l c]
                   (when (or (zero? (long l)) (> (Math/abs (long l)) n))
                     (throw (ex-info "literal out of range" {:literal l :num-vars n}))))
                 (if (add-clause! s c) (recur (next cs)) false))
               true))
        stats #(hash-map :conflicts (aget iv I-CONFLICTS) :decisions (aget iv I-DECISIONS))]
    (if-not ok
      (assoc (stats) :status :unsat)
      (let [dv ^doubles (.-dv s)]
        (aset dv D-MAX-LEARNTS (double (max (quot (aget iv I-STORED) 3) 2000)))
        (loop [i 0]
          (let [r (search! s (long (* 100 (luby/luby 2.0 i))))]
            (case r
              :sat (assoc (stats) :status :sat :model (extract-model s))
              :unsat (assoc (stats) :status :unsat)
              :restart
              (do (when (>= (.size ^ArrayList (.-learnts s)) (aget dv D-MAX-LEARNTS))
                    (reduce-db! s)
                    (aset dv D-MAX-LEARNTS (* 1.1 (aget dv D-MAX-LEARNTS))))
                  (recur (inc i))))))))))
