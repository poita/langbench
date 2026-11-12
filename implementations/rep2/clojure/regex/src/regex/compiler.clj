(ns regex.compiler
  "Compiles a syntax tree (see regex.parser) into a backtracking program.

  A program is an `int-array` of fixed-width instructions `[op a b c]`
  (4 ints each) plus an array of charsets.  Counted quantifiers over groups
  and other composite atoms are expanded into copies of the atom.

  Opcodes (see regex.vm for their execution):

      0  CHAR a=code          match one literal character
      1  ANY                  match any character
      2  SET a=set-index      match a character in the set
      3  BOL                  succeed only at position 0
      4  EOL                  succeed only at the end of the subject
      5  SPLIT a b            try pc=a first, backtrack to pc=b
      6  JMP a                continue at pc=a
      7  SAVE a=reg           regs[a] = pos   (trailed)
      8  CLOSE a=cap b=tmp    group completed: caps = (regs[tmp], pos)
      9  EMPTYCHK a=reg b=pc  if the iteration was empty, continue at pc=b
      10 MATCH                overall success
      11 REPCHAR a=code b=min c=max   greedy run of one literal (max -1 = inf)
      12 REPANY  b=min c=max          greedy run of `.`
      13 REPSET  a=set-index b=min c=max

  Register layout: 2 slots per group (start,end), then 1 temporary start slot
  per group, then one slot per quantified composite atom that can match empty."
  (:require [regex.analysis :as analysis]))

(def op-char 0) (def op-any 1) (def op-set 2) (def op-bol 3) (def op-eol 4)
(def op-split 5) (def op-jmp 6) (def op-save 7) (def op-close 8)
(def op-emptychk 9) (def op-match 10)
(def op-repchar 11) (def op-repany 12) (def op-repset 13)

(def ^:const width "Ints per instruction." 4)

(defn- simple? [node] (contains? #{:char :any :set} (node 0)))

(defn compile-ast
  "Compiles `ast` for a pattern with `ngroups` groups.  Returns a map
  `{:code int-array :sets object-array :nregs n}`."
  [ast ngroups]
  (let [^java.util.ArrayList code (java.util.ArrayList.)
        ^java.util.ArrayList sets (java.util.ArrayList.)
        nloops (volatile! 0)
        emit! (fn [op a b c]
                (.add code (int-array [op a b c]))
                (dec (.size code)))
        here (fn [] (.size code))
        patch! (fn [idx slot v] (aset ^ints (.get code idx) (int slot) (int v)))
        add-set! (fn [t] (.add sets t) (dec (.size sets)))
        loop-reg! (fn [] (+ (* 3 ngroups) (dec (vswap! nloops inc))))
        emit-simple-rep! (fn [[kind v] mn mx]
                           (let [mx (or mx -1)]
                             (case kind
                               :char (emit! op-repchar v mn mx)
                               :any (emit! op-repany 0 mn mx)
                               :set (emit! op-repset (add-set! v) mn mx))))]
    (letfn [(emit-node [node]
              (case (node 0)
                :char (emit! op-char (node 1) 0 0)
                :any (emit! op-any 0 0 0)
                :set (emit! op-set (add-set! (node 1)) 0 0)
                :bol (emit! op-bol 0 0 0)
                :eol (emit! op-eol 0 0 0)
                :seq (doseq [x (node 1)] (emit-node x))
                :alt (emit-alt (node 1))
                :group (let [g (node 1)
                             tmp (+ (* 2 ngroups) (dec g))]
                         (emit! op-save tmp 0 0)
                         (emit-node (node 2))
                         (emit! op-close (* 2 (dec g)) tmp 0))
                :rep (emit-rep node)))
            (emit-alt [branches]
              (let [jumps (volatile! [])]
                (doseq [b (butlast branches)]
                  (let [split (emit! op-split (inc (here)) 0 0)]
                    (emit-node b)
                    (vswap! jumps conj (emit! op-jmp 0 0 0))
                    (patch! split 2 (here))))
                (emit-node (last branches))
                (doseq [j @jumps] (patch! j 1 (here)))))
            ;; one optional iteration: body, with an empty-iteration check
            ;; that jumps to the end of the whole repetition
            (emit-iteration [x reg ends]
              (when reg (emit! op-save reg 0 0))
              (emit-node x)
              (when reg (vswap! ends conj (emit! op-emptychk reg 0 0))))
            (emit-rep [[_ x mn mx]]
              (cond
                (and mx (zero? mx)) nil
                (and (= mn 1) (= mx 1)) (emit-node x)
                (simple? x) (emit-simple-rep! x mn mx)
                :else
                (let [reg (when (analysis/nullable? x) (loop-reg!))
                      ends (volatile! [])
                      splits (volatile! [])]
                  (dotimes [_ mn] (emit-node x))
                  (if (nil? mx)
                    (let [top (here)
                          split (emit! op-split (inc (here)) 0 0)]
                      (emit-iteration x reg ends)
                      (emit! op-jmp top 0 0)
                      (vswap! splits conj split))
                    (dotimes [_ (- mx mn)]
                      (let [split (emit! op-split (inc (here)) 0 0)]
                        (vswap! splits conj split)
                        (emit-iteration x reg ends))))
                  (let [end (here)]
                    (doseq [s @splits] (patch! s 2 end))
                    (doseq [e @ends] (patch! e 2 end))))))]
      (emit-node ast)
      (emit! op-match 0 0 0)
      (let [n (.size code)
            flat (int-array (* n width))]
        (dotimes [i n]
          (System/arraycopy ^ints (.get code i) 0 flat (* i width) width))
        {:code flat
         :sets (.toArray sets)
         :nregs (+ (* 3 ngroups) @nloops)}))))
