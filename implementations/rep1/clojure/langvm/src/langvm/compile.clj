(ns langvm.compile
  "Bytecode compiler: lowers the checked IR of `langvm.check` to the
  instruction set of `langvm.bytecode` (SPEC section 16).

  `(compile-program prog bodies)` returns a map

    {:consts Object[]   :code Object[] of int[] (one per function)
     :nlocals int[]     :impl-table Object[] of int[] or nil
     :ncon long         :main function-index}

  Function indices are the program's function ids; lambdas are appended."
  (:require [langvm.bytecode :refer [op]]
            [langvm.runtime :as rt]
            [langvm.types :as t])
  (:import (java.util ArrayList HashMap)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; emission

(defn- emit!
  "Append instruction `opn` with `operands`.  An operand that is a label (an
  atom) is patched when the label is placed."
  [cx opn & operands]
  (let [^ArrayList c (:code cx)]
    (.add c (int (op opn)))
    (doseq [x operands]
      (if (instance? clojure.lang.Atom x)
        (if-let [p (:pos @x)]
          (.add c (int p))
          (do (swap! x update :refs conj (.size c))
              (.add c (int 0))))
        (.add c (int x))))))

(defn- here ^long [cx] (.size ^ArrayList (:code cx)))

(defn- mk-label [] (atom {:pos nil :refs []}))

(defn- place! [cx label]
  (let [p (here cx)]
    (swap! label assoc :pos p)
    (doseq [r (:refs @label)]
      (.set ^ArrayList (:code cx) (int r) (int p)))))

(defn- const! [cx v]
  (let [g (:g cx)
        ^HashMap idx (:const-idx g)]
    (or (.get idx v)
        (let [^ArrayList pool (:consts g)
              i (.size pool)]
          (.add pool v)
          (.put idx v (int i))
          i))))

(defn- slot-of
  "Frame slot of binding `b`, allocating one on first sight."
  [cx b]
  (let [^HashMap slots (:slots cx)
        id (:id b)]
    (or (.get slots id)
        (let [^longs nx (:next cx)
              s (aget nx 0)]
          (aset nx 0 (inc s))
          (.put slots id (int s))
          (int s)))))

(defn- temp! [cx]
  (let [^longs nx (:next cx) s (aget nx 0)]
    (aset nx 0 (inc s))
    (int s)))

(defn- emit-load! [cx b]
  (let [^HashMap slots (:slots cx)]
    (if-let [s (.get slots (:id b))]
      (emit! cx :LOAD_LOCAL s)
      (emit! cx :LOAD_UPVAL (get (:ups cx) (:id b))))))

;; ---------------------------------------------------------------------------
;; patterns

(declare cexp cstmt)

(defn- lit-const [cx p]
  (case (:ty p)
    :int (const! cx (Long/valueOf (long (:v p))))
    :char (const! cx (Integer/valueOf (int (:v p))))
    :str (const! cx (rt/vstr (:v p)))
    :bool nil))

(defn- store-sub!
  "After the sub-value is on the stack, store it for sub-pattern `sp`;
  returns the slot to match against or nil when the value was consumed."
  [cx sp]
  (case (:k sp)
    :wild (do (emit! cx :POP) nil)
    :bind (do (emit! cx :STORE_LOCAL (slot-of cx (:b sp))) nil)
    (let [s (temp! cx)] (emit! cx :STORE_LOCAL s) s)))

(defn- match-pattern!
  "Emit code matching pattern `p` against the value in slot `src`.  When
  `fail` is non-nil a mismatch jumps to it; with nil the pattern is known to
  be irrefutable."
  [cx p src fail]
  (case (:k p)
    :wild nil
    :bind (do (emit! cx :LOAD_LOCAL src) (emit! cx :STORE_LOCAL (slot-of cx (:b p))))
    :lit (do (emit! cx :LOAD_LOCAL src)
             (if (= :bool (:ty p))
               (emit! cx (if (:v p) :JUMP_IF_FALSE :JUMP_IF_TRUE) fail)
               (do (emit! cx :PUSH_CONST (lit-const cx p))
                   (emit! cx :EQ)
                   (emit! cx :JUMP_IF_FALSE fail))))
    :variant
    (do
      (when fail
        (emit! cx :LOAD_LOCAL src)
        (emit! cx :IS_VARIANT (:vidx p))
        (emit! cx :JUMP_IF_FALSE fail))
      (doseq [[i sp] (map-indexed vector (:args p))
              :when (not= :wild (:k sp))]
        (emit! cx :LOAD_LOCAL src)
        (emit! cx :GET_PAYLOAD i)
        (when-let [s (store-sub! cx sp)] (match-pattern! cx sp s fail))))
    :struct
    (doseq [[i sp] (map-indexed vector (:fields p))
            :when (not= :wild (:k sp))]
      (emit! cx :LOAD_LOCAL src)
      (emit! cx :GET_FIELD i)
      (when-let [s (store-sub! cx sp)] (match-pattern! cx sp s fail)))
    :tuple
    (doseq [[i sp] (map-indexed vector (:elems p))
            :when (not= :wild (:k sp))]
      (emit! cx :LOAD_LOCAL src)
      (emit! cx :GET_TUPLE i)
      (when-let [s (store-sub! cx sp)] (match-pattern! cx sp s fail)))
    :list
    (let [n (count (:elems p))]
      (when fail
        (emit! cx :LOAD_LOCAL src)
        (emit! cx :SEQ_LEN)
        (emit! cx :PUSH_CONST (const! cx (Long/valueOf (long n))))
        (emit! cx (if (:rest p) :GE :EQ))
        (emit! cx :JUMP_IF_FALSE fail))
      (doseq [[i sp] (map-indexed vector (:elems p))
              :when (not= :wild (:k sp))]
        (emit! cx :LOAD_LOCAL src)
        (emit! cx :PUSH_CONST (const! cx (Long/valueOf (long i))))
        (emit! cx :SEQ_GET)
        (when-let [s (store-sub! cx sp)] (match-pattern! cx sp s fail)))
      (when-let [b (:rest-bind p)]
        (emit! cx :LOAD_LOCAL src)
        (emit! cx :LIST_REST n)
        (emit! cx :STORE_LOCAL (slot-of cx b))))))

(defn- bind-irrefutable!
  "Bind pattern `p` to the value on top of the stack (consumed)."
  [cx p]
  (case (:k p)
    :wild (emit! cx :POP)
    :bind (emit! cx :STORE_LOCAL (slot-of cx (:b p)))
    (let [s (temp! cx)]
      (emit! cx :STORE_LOCAL s)
      (match-pattern! cx p s nil))))

;; ---------------------------------------------------------------------------
;; expressions

(def ^:private binop-codes
  {:add-i :ADD_I :sub-i :SUB_I :mul-i :MUL_I :div-i :DIV_I :mod-i :MOD_I
   :add-f :ADD_F :sub-f :SUB_F :mul-f :MUL_F :div-f :DIV_F
   :band :BAND :bor :BOR :bxor :BXOR :shl :SHL :shr :SHR
   :eq :EQ :ne :NE :lt :LT :le :LE :gt :GT :ge :GE
   :concat-str :CONCAT_STR :concat-list :CONCAT_LIST})

(declare compile-lambda!)

(defn- cexps [cx irs] (doseq [ir irs] (cexp cx ir)))

(defn cexp
  "Emit code that pushes the value of IR expression `ir`."
  [cx ir]
  (case (nth ir 0)
    :int (emit! cx :PUSH_CONST (const! cx (Long/valueOf (long (nth ir 1)))))
    :float (emit! cx :PUSH_CONST (const! cx (Double/valueOf (double (nth ir 1)))))
    :char (emit! cx :PUSH_CONST (const! cx (Integer/valueOf (int (nth ir 1)))))
    :str (emit! cx :PUSH_CONST (const! cx (rt/vstr (nth ir 1))))
    :bool (emit! cx (if (nth ir 1) :PUSH_TRUE :PUSH_FALSE))
    :var (emit-load! cx (nth ir 1))
    :unop (do (cexp cx (nth ir 2))
              (emit! cx (case (nth ir 1) :neg-i :NEG_I :neg-f :NEG_F :not :NOT_B :bnot :BNOT)))
    :binop
    (let [o (nth ir 1)]
      (case o
        :and (let [lf (mk-label) end (mk-label)]
               (cexp cx (nth ir 2))
               (emit! cx :JUMP_IF_FALSE lf)
               (cexp cx (nth ir 3))
               (emit! cx :JUMP end)
               (place! cx lf)
               (emit! cx :PUSH_FALSE)
               (place! cx end))
        :or (let [lt (mk-label) end (mk-label)]
              (cexp cx (nth ir 2))
              (emit! cx :JUMP_IF_TRUE lt)
              (cexp cx (nth ir 3))
              (emit! cx :JUMP end)
              (place! cx lt)
              (emit! cx :PUSH_TRUE)
              (place! cx end))
        (do (cexp cx (nth ir 2))
            (cexp cx (nth ir 3))
            (emit! cx (get binop-codes o)))))
    :index (do (cexp cx (nth ir 1)) (cexp cx (nth ir 2)) (emit! cx :INDEX_GET))
    :field (do (cexp cx (nth ir 1)) (emit! cx :GET_FIELD (nth ir 2)))
    :make-list (do (cexps cx (nth ir 1)) (emit! cx :MAKE_LIST (count (nth ir 1))))
    :make-map (let [es (nth ir 1)]
                (doseq [[k v] es] (cexp cx k) (cexp cx v))
                (emit! cx :MAKE_MAP (count es)))
    :make-tuple (do (cexps cx (nth ir 1)) (emit! cx :MAKE_TUPLE (count (nth ir 1))))
    :make-struct
    (let [fields (nth ir 2)
          n (count fields)]
      (if (= (map first fields) (range n))
        (cexps cx (map second fields))
        (let [temps (mapv (fn [[idx fir]]
                            (cexp cx fir)
                            (let [s (temp! cx)] (emit! cx :STORE_LOCAL s) [idx s]))
                          fields)
              by-idx (into {} temps)]
          (dotimes [i n] (emit! cx :LOAD_LOCAL (get by-idx i)))))
      (emit! cx :MAKE_STRUCT (nth ir 1) n))
    :make-enum (do (cexps cx (nth ir 3))
                   (emit! cx :MAKE_ENUM (nth ir 1) (nth ir 2) (count (nth ir 3))))
    :call-fn (do (cexps cx (nth ir 2)) (emit! cx :CALL (nth ir 1) (count (nth ir 2))))
    :call-builtin (do (cexps cx (nth ir 2)) (emit! cx :CALL_BUILTIN (nth ir 1) (count (nth ir 2))))
    :call-method (do (cexp cx (nth ir 3))
                     (cexps cx (nth ir 4))
                     (emit! cx :CALL_METHOD (nth ir 1) (nth ir 2) (count (nth ir 4))))
    :call-value (do (cexp cx (nth ir 1))
                    (cexps cx (nth ir 2))
                    (emit! cx :CALL_VALUE (count (nth ir 2))))
    :lambda
    (let [lam (nth ir 1)
          idx (compile-lambda! (:g cx) lam)]
      (doseq [b (:captures lam)] (emit-load! cx b))
      (emit! cx :MAKE_CLOSURE idx (count (:captures lam))))
    :if
    (let [[_ c th el] ir
          lelse (mk-label) end (mk-label)]
      (cexp cx c)
      (emit! cx :JUMP_IF_FALSE lelse)
      (cexp cx th)
      (emit! cx :JUMP end)
      (place! cx lelse)
      (if el (cexp cx el) (emit! cx :PUSH_UNIT))
      (place! cx end))
    :match
    (let [[_ scrut arms] ir
          s (temp! cx)
          end (mk-label)]
      (cexp cx scrut)
      (emit! cx :STORE_LOCAL s)
      (doseq [{:keys [pat guard body]} arms]
        (let [next (mk-label)]
          (match-pattern! cx pat s next)
          (when guard
            (cexp cx guard)
            (emit! cx :JUMP_IF_FALSE next))
          (cexp cx body)
          (emit! cx :JUMP end)
          (place! cx next)))
      (emit! cx :NO_MATCH)
      (place! cx end))
    :block
    (let [[_ stmts tail] ir]
      (doseq [s stmts] (cstmt cx s))
      (if tail (cexp cx tail) (emit! cx :PUSH_UNIT)))))

;; ---------------------------------------------------------------------------
;; statements

(defn- push-loop! [cx brk cont sp-slot]
  (vswap! (:loops cx) conj {:break brk :continue cont :sp sp-slot}))

(defn- pop-loop! [cx] (vswap! (:loops cx) pop))

(defn- cblock-effects
  "Emit a loop body block for its effects only."
  [cx block]
  (let [[_ stmts tail] block]
    (doseq [s stmts] (cstmt cx s))
    (when tail (cexp cx tail) (emit! cx :POP))))

(defn cstmt
  "Emit code for IR statement `s` (leaves the stack unchanged)."
  [cx s]
  (case (nth s 0)
    :expr (do (cexp cx (nth s 1)) (emit! cx :POP))
    :let (do (cexp cx (nth s 2)) (bind-irrefutable! cx (nth s 1)))
    :var-decl (do (cexp cx (nth s 2)) (emit! cx :STORE_LOCAL (slot-of cx (nth s 1))))
    :assign-var (do (cexp cx (nth s 2)) (emit! cx :STORE_LOCAL (slot-of cx (nth s 1))))
    :assign-index (do (cexp cx (nth s 1)) (cexp cx (nth s 2)) (cexp cx (nth s 3))
                      (emit! cx :INDEX_SET))
    :while
    (let [cond-l (mk-label) end (mk-label) sps (temp! cx)]
      (emit! cx :SAVE_SP sps)
      (place! cx cond-l)
      (cexp cx (nth s 1))
      (emit! cx :JUMP_IF_FALSE end)
      (push-loop! cx end cond-l sps)
      (cblock-effects cx (nth s 2))
      (pop-loop! cx)
      (emit! cx :JUMP cond-l)
      (place! cx end))
    :for-seq
    (let [[_ pat seq-ir body] s
          cond-l (mk-label) end (mk-label)
          sq (temp! cx) ix (temp! cx) dst (temp! cx) sps (temp! cx)]
      (cexp cx seq-ir)
      (emit! cx :STORE_LOCAL sq)
      (emit! cx :PUSH_CONST (const! cx (Long/valueOf 0)))
      (emit! cx :STORE_LOCAL ix)
      (emit! cx :SAVE_SP sps)
      (place! cx cond-l)
      (emit! cx :ITER_NEXT sq ix end dst)
      (match-pattern! cx pat dst nil)
      (push-loop! cx end cond-l sps)
      (cblock-effects cx body)
      (pop-loop! cx)
      (emit! cx :JUMP cond-l)
      (place! cx end))
    :for-range
    (let [[_ pat lo hi body] s
          cond-l (mk-label) end (mk-label)
          ix (temp! cx) hs (temp! cx) dst (temp! cx) sps (temp! cx)]
      (cexp cx lo)
      (emit! cx :STORE_LOCAL ix)
      (cexp cx hi)
      (emit! cx :STORE_LOCAL hs)
      (emit! cx :SAVE_SP sps)
      (place! cx cond-l)
      (emit! cx :RANGE_NEXT ix hs end dst)
      (match-pattern! cx pat dst nil)
      (push-loop! cx end cond-l sps)
      (cblock-effects cx body)
      (pop-loop! cx)
      (emit! cx :JUMP cond-l)
      (place! cx end))
    :return (do (if (nth s 1) (cexp cx (nth s 1)) (emit! cx :PUSH_UNIT))
                (emit! cx :RET))
    :break (let [l (peek @(:loops cx))]
             (emit! cx :RESTORE_SP (:sp l))
             (emit! cx :JUMP (:break l)))
    :continue (let [l (peek @(:loops cx))]
                (emit! cx :RESTORE_SP (:sp l))
                (emit! cx :JUMP (:continue l)))))

;; ---------------------------------------------------------------------------
;; functions

(defn- new-cx [g params captures]
  (let [cx {:g g :code (ArrayList.) :slots (HashMap.) :next (long-array 1)
            :ups (into {} (map-indexed (fn [i b] [(:id b) i])) captures)
            :loops (volatile! [])}]
    (doseq [b params] (slot-of cx b))
    cx))

(defn- compile-body! [g idx params body captures]
  (let [cx (new-cx g params captures)]
    (cexp cx body)
    (emit! cx :RET)
    (.set ^ArrayList (:fns g) (int idx)
          {:code (int-array (:code cx))
           :nlocals (aget ^longs (:next cx) 0)})))

(defn- compile-lambda! [g lam]
  (let [^ArrayList fns (:fns g)
        idx (.size fns)]
    (.add fns nil)
    (compile-body! g idx (:params lam) (:body lam) (:captures lam))
    idx))

(defn- build-impl-table [prog ncon]
  (let [tbl (object-array (* (count (:traits-table prog)) ncon))]
    (doseq [im (:impls prog)]
      (let [trait (nth (:traits-table prog) (:trait im))
            by-name (into {} (map (juxt :name :fn)) (:methods im))
            fids (mapv (fn [m] (or (get by-name (:name m)) (:default m))) (:methods trait))]
        (aset tbl (+ (* (long (:trait im)) ncon) (long (t/head-con (:head im)))) (int-array fids))))
    tbl))

(defn compile-program
  "Compile the typed `bodies` (from `langvm.check/check-program`)."
  [prog bodies]
  (let [g {:consts (ArrayList.) :const-idx (HashMap.)
           :fns (let [l (ArrayList.)] (dotimes [_ (count (:fns prog))] (.add l nil)) l)}]
    (doseq [fid (:body-order prog)]
      (let [{:keys [params body]} (get bodies fid)]
        (compile-body! g fid params body [])))
    (let [^ArrayList fns (:fns g)
          ncon (+ 8 (count (:decls prog)))]
      {:consts (.toArray ^ArrayList (:consts g))
       :code (object-array (map :code fns))
       :nlocals (int-array (map :nlocals fns))
       :impl-table (build-impl-table prog ncon)
       :ncon ncon
       :main (:main prog)})))
