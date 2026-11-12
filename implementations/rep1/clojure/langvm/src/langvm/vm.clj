(ns langvm.vm
  "The stack machine (SPEC section 16).

  [[run]] executes a compiled program.  The interpreter is a flat loop with
  its own frame arrays, so Vellum call depth is independent of the host stack;
  higher-order built-ins re-enter the loop through `ICaller/call`."
  (:require [langvm.bytecode :refer [opcase]]
            [langvm.runtime :as rt :refer [panic UNIT]]
            [langvm.stdlib :as stdlib])
  (:import (java.util ArrayList LinkedHashMap)
           (langvm.runtime VStr Rec Closure ICaller)))

(set! *warn-on-reflection* true)

(def ^:const max-frames 20000)
(def ^:private ^:const stack-margin 4096)

(defn- grow-stack
  "A copy of `stack` with room for at least `need` entries."
  ^objects [^objects stack ^long need]
  (let [n (max need (* 2 (alength stack)))
        new (object-array n)]
    (System/arraycopy stack 0 new 0 (alength stack))
    new))

;; Rarely used operations live outside the interpreter loop so that the loop
;; method stays small enough for the JIT.

(defn- index-get [c i]
  (cond
    (instance? ArrayList c)
    (let [^ArrayList c c i (long i)]
      (when (or (neg? i) (>= i (.size c))) (panic "index out of bounds"))
      (.get c (int i)))
    (instance? VStr c)
    (let [^VStr c c i (long i)]
      (when (or (neg? i) (>= i (.len c))) (panic "index out of bounds"))
      (if (.bmp c)
        (Integer/valueOf (int (.charAt ^String (.s c) (int i))))
        (let [^String s (.s c)] (Integer/valueOf (.codePointAt s (.offsetByCodePoints s 0 (int i)))))))
    :else
    (let [v (.get ^LinkedHashMap c i)]
      (if (nil? v) (panic "missing key") v))))

(defn- index-set [c i v]
  (if (instance? ArrayList c)
    (let [^ArrayList c c i (long i)]
      (when (or (neg? i) (>= i (.size c))) (panic "index out of bounds"))
      (.set c (int i) v))
    (.put ^LinkedHashMap c i v))
  nil)

(defn- concat-str [^VStr a ^VStr b]
  (VStr. (.concat ^String (.s a) ^String (.s b)) (+ (.len a) (.len b)) (and (.bmp a) (.bmp b))))

(defn- concat-list [^ArrayList a ^ArrayList b]
  (let [out (ArrayList. (+ (.size a) (.size b)))]
    (.addAll out a)
    (.addAll out b)
    out))

(defn- list-rest [^ArrayList xs ^long i]
  (ArrayList. (.subList xs (int i) (.size xs))))

(defn- seq-len [x]
  (long (.size ^ArrayList x)))

(defn- make-map [^objects stack ^long base ^long n]
  (let [m (LinkedHashMap.)]
    (dotimes [i n]
      (.put m (aget stack (+ base (* 2 i))) (aget stack (+ base (* 2 i) 1))))
    m))

(defn- slice-array [^objects stack ^long base ^long n]
  (let [a (object-array n)]
    (System/arraycopy stack base a 0 n)
    a))

(defn- make-list [^objects stack ^long base ^long n]
  (let [l (ArrayList. (int n))]
    (dotimes [i n] (.add l (aget stack (+ base i))))
    l))

(declare exec)

(deftype Machine [^objects stackref ^longs regs
                  ^longs frpc ^longs frbp ^longs frsp ^objects frcode ^objects frups
                  ^objects consts ^objects codes ^ints nlocals
                  ^objects impl-table ^long ncon ^objects builtins]
  ICaller
  (call [this f args]
    (let [^Closure c f
          ^objects stack (aget stackref 0)
          sp (aget regs 0)
          argc (alength args)
          stack (if (> (+ sp argc) (- (alength stack) stack-margin))
                  (let [s (grow-stack stack (+ sp argc stack-margin))] (aset stackref 0 s) s)
                  stack)]
      (System/arraycopy args 0 ^objects stack sp argc)
      (aset regs 0 (+ sp argc))
      (let [r (langvm.vm/exec this (.fn c) (.ups c) argc)]
        r))))

(defmacro ^:private nxt [pc sp]
  `(recur ~pc ~sp ~'bp ~'fp ~'code ~'ups ~'stack))

(defmacro ^:private boxl [x] `(Long/valueOf (long ~x)))
(defmacro ^:private boxd [x] `(Double/valueOf (double ~x)))

(defmacro ^:private sref [i] `(aget ~'stack (+ ~'bp ~i)))

(defn exec
  "Run function `fn-idx` with `argc` arguments already on the stack (top of
  the stack per `regs`) and upvalues `ups`; returns its result."
  [^Machine m ^long fn-idx ups ^long argc]
  (let [^longs regs (.regs m)
        ^longs frpc (.frpc m) ^longs frbp (.frbp m) ^longs frsp (.frsp m)
        ^objects frcode (.frcode m) ^objects frups (.frups m)
        ^objects consts (.consts m) ^objects codes (.codes m) ^ints nlocals (.nlocals m)
        ^objects impl-table (.impl-table m) ncon (.ncon m) ^objects builtins (.builtins m)
        ^objects stackref (.stackref m)
        sp0 (aget regs 0)
        fp0 (inc (aget regs 1))]
    (when (> fp0 max-frames) (panic "call stack overflow"))
    (let [bp0 (- sp0 argc)
          nsp (+ bp0 (aget nlocals fn-idx))
          ^objects stack0 (let [^objects s (aget stackref 0)]
                            (if (> (+ nsp stack-margin) (alength s))
                              (let [s2 (grow-stack s (+ nsp stack-margin))] (aset stackref 0 s2) s2)
                              s))]
      (aset frpc fp0 -1)
      (aset frsp fp0 bp0)
      (loop [pc 0, sp nsp, bp bp0, fp fp0, ^ints code (aget codes fn-idx), ^objects ups ups,
             ^objects stack stack0]
        (opcase (aget code pc)
          PUSH_CONST (do (aset stack sp (aget consts (aget code (+ pc 1)))) (nxt (+ pc 2) (inc sp)))
          PUSH_TRUE (do (aset stack sp Boolean/TRUE) (nxt (inc pc) (inc sp)))
          PUSH_FALSE (do (aset stack sp Boolean/FALSE) (nxt (inc pc) (inc sp)))
          PUSH_UNIT (do (aset stack sp UNIT) (nxt (inc pc) (inc sp)))
          LOAD_LOCAL (do (aset stack sp (sref (aget code (+ pc 1)))) (nxt (+ pc 2) (inc sp)))
          STORE_LOCAL (do (aset stack (+ bp (aget code (+ pc 1))) (aget stack (dec sp))) (nxt (+ pc 2) (dec sp)))
          LOAD_UPVAL (do (aset stack sp (aget ups (aget code (+ pc 1)))) (nxt (+ pc 2) (inc sp)))
          POP (nxt (inc pc) (dec sp))
          DUP (do (aset stack sp (aget stack (dec sp))) (nxt (inc pc) (inc sp)))
          MAKE_CLOSURE
          (let [n (aget code (+ pc 2))
                nsp (- sp n)]
            (aset stack nsp (Closure. (aget code (+ pc 1)) (slice-array stack nsp n)))
            (nxt (+ pc 3) (inc nsp)))
          CALL
          (let [f (aget code (+ pc 1)) argc (aget code (+ pc 2))]
            (when (>= fp max-frames) (panic "call stack overflow"))
            (let [nfp (inc fp) nbp (- sp argc)
                  nsp (+ nbp (aget nlocals f))
                  stack (if (> (+ nsp stack-margin) (alength stack))
                          (let [s (grow-stack stack (+ nsp stack-margin))] (aset stackref 0 s) s)
                          stack)]
              (aset frpc nfp (+ pc 3)) (aset frbp nfp bp) (aset frsp nfp nbp)
              (aset frcode nfp code) (aset frups nfp ups)
              (recur 0 nsp nbp nfp (aget codes f) nil stack)))
          CALL_VALUE
          (let [argc (aget code (+ pc 1))]
            (when (>= fp max-frames) (panic "call stack overflow"))
            (let [^Closure c (aget stack (- sp argc 1))
                  f (.fn c)
                  nfp (inc fp) nbp (- sp argc)
                  nsp (+ nbp (aget nlocals f))
                  stack (if (> (+ nsp stack-margin) (alength stack))
                          (let [s (grow-stack stack (+ nsp stack-margin))] (aset stackref 0 s) s)
                          stack)]
              (aset frpc nfp (+ pc 2)) (aset frbp nfp bp) (aset frsp nfp (dec nbp))
              (aset frcode nfp code) (aset frups nfp ups)
              (recur 0 nsp nbp nfp (aget codes f) (.ups c) stack)))
          CALL_METHOD
          (let [t (aget code (+ pc 1)) mi (aget code (+ pc 2)) argc (aget code (+ pc 3))]
            (when (>= fp max-frames) (panic "call stack overflow"))
            (let [nbp (- sp argc 1)
                  recv (aget stack nbp)
                  ^ints fids (aget impl-table (+ (* t ncon) (rt/tag-of recv)))
                  f (aget fids mi)
                  nfp (inc fp)
                  nsp (+ nbp (aget nlocals f))
                  stack (if (> (+ nsp stack-margin) (alength stack))
                          (let [s (grow-stack stack (+ nsp stack-margin))] (aset stackref 0 s) s)
                          stack)]
              (aset frpc nfp (+ pc 4)) (aset frbp nfp bp) (aset frsp nfp nbp)
              (aset frcode nfp code) (aset frups nfp ups)
              (recur 0 nsp nbp nfp (aget codes f) nil stack)))
          CALL_BUILTIN
          (let [b (aget code (+ pc 1)) argc (aget code (+ pc 2))
                base (- sp argc)
                ^clojure.lang.IFn f (aget builtins b)]
            (aset regs 0 sp)
            (aset regs 1 fp)
            (let [r (case argc
                      0 (.invoke f m)
                      1 (.invoke f m (aget stack base))
                      2 (.invoke f m (aget stack base) (aget stack (+ base 1)))
                      3 (.invoke f m (aget stack base) (aget stack (+ base 1)) (aget stack (+ base 2))))
                  ^objects stack (aget stackref 0)]
              (aset stack base r)
              (recur (+ pc 3) (inc base) bp fp code ups stack)))
          RET
          (let [r (aget stack (dec sp))
                rpc (aget frpc fp)
                rsp (aget frsp fp)]
            (if (neg? rpc)
              (do (aset regs 0 rsp) (aset regs 1 (dec fp)) r)
              (do (aset stack rsp r)
                  (recur rpc (inc rsp) (aget frbp fp) (dec fp) (aget frcode fp) (aget frups fp) stack))))
          RET_UNIT
          (let [rpc (aget frpc fp)
                rsp (aget frsp fp)]
            (if (neg? rpc)
              (do (aset regs 0 rsp) (aset regs 1 (dec fp)) UNIT)
              (do (aset stack rsp UNIT)
                  (recur rpc (inc rsp) (aget frbp fp) (dec fp) (aget frcode fp) (aget frups fp) stack))))
          ADD_I (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                  (aset stack (- sp 2) (boxl (unchecked-add a b))) (nxt (inc pc) (dec sp)))
          SUB_I (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                  (aset stack (- sp 2) (boxl (unchecked-subtract a b))) (nxt (inc pc) (dec sp)))
          MUL_I (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                  (aset stack (- sp 2) (boxl (unchecked-multiply a b))) (nxt (inc pc) (dec sp)))
          DIV_I (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                  (when (zero? b) (panic "divide by zero"))
                  (aset stack (- sp 2) (boxl (quot a b))) (nxt (inc pc) (dec sp)))
          MOD_I (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                  (when (zero? b) (panic "modulo by zero"))
                  (aset stack (- sp 2) (boxl (rem a b))) (nxt (inc pc) (dec sp)))
          NEG_I (do (aset stack (dec sp) (boxl (unchecked-negate (long (aget stack (dec sp)))))) (nxt (inc pc) sp))
          BNOT (do (aset stack (dec sp) (boxl (bit-not (long (aget stack (dec sp)))))) (nxt (inc pc) sp))
          BAND (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                 (aset stack (- sp 2) (boxl (bit-and a b))) (nxt (inc pc) (dec sp)))
          BOR (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                (aset stack (- sp 2) (boxl (bit-or a b))) (nxt (inc pc) (dec sp)))
          BXOR (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                 (aset stack (- sp 2) (boxl (bit-xor a b))) (nxt (inc pc) (dec sp)))
          SHL (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                (when (or (neg? b) (> b 63)) (panic "shift amount out of range"))
                (aset stack (- sp 2) (boxl (bit-shift-left a b))) (nxt (inc pc) (dec sp)))
          SHR (let [b (long (aget stack (dec sp))) a (long (aget stack (- sp 2)))]
                (when (or (neg? b) (> b 63)) (panic "shift amount out of range"))
                (aset stack (- sp 2) (boxl (bit-shift-right a b))) (nxt (inc pc) (dec sp)))
          ADD_F (let [b (double (aget stack (dec sp))) a (double (aget stack (- sp 2)))]
                  (aset stack (- sp 2) (boxd (+ a b))) (nxt (inc pc) (dec sp)))
          SUB_F (let [b (double (aget stack (dec sp))) a (double (aget stack (- sp 2)))]
                  (aset stack (- sp 2) (boxd (- a b))) (nxt (inc pc) (dec sp)))
          MUL_F (let [b (double (aget stack (dec sp))) a (double (aget stack (- sp 2)))]
                  (aset stack (- sp 2) (boxd (* a b))) (nxt (inc pc) (dec sp)))
          DIV_F (let [b (double (aget stack (dec sp))) a (double (aget stack (- sp 2)))]
                  (aset stack (- sp 2) (boxd (/ a b))) (nxt (inc pc) (dec sp)))
          NEG_F (do (aset stack (dec sp) (boxd (- (double (aget stack (dec sp)))))) (nxt (inc pc) sp))
          NOT_B (do (aset stack (dec sp) (if (.booleanValue ^Boolean (aget stack (dec sp))) Boolean/FALSE Boolean/TRUE))
                    (nxt (inc pc) sp))
          EQ (let [b (aget stack (dec sp)) a (aget stack (- sp 2))]
               (aset stack (- sp 2) (if (rt/veq a b) Boolean/TRUE Boolean/FALSE)) (nxt (inc pc) (dec sp)))
          NE (let [b (aget stack (dec sp)) a (aget stack (- sp 2))]
               (aset stack (- sp 2) (if (rt/veq a b) Boolean/FALSE Boolean/TRUE)) (nxt (inc pc) (dec sp)))
          LT (let [b (aget stack (dec sp)) a (aget stack (- sp 2))]
               (aset stack (- sp 2) (if (if (instance? Long a) (< (long a) (long b)) (rt/vlt a b)) Boolean/TRUE Boolean/FALSE))
               (nxt (inc pc) (dec sp)))
          LE (let [b (aget stack (dec sp)) a (aget stack (- sp 2))]
               (aset stack (- sp 2) (if (if (instance? Long a) (<= (long a) (long b)) (rt/vle a b)) Boolean/TRUE Boolean/FALSE))
               (nxt (inc pc) (dec sp)))
          GT (let [b (aget stack (dec sp)) a (aget stack (- sp 2))]
               (aset stack (- sp 2) (if (if (instance? Long a) (> (long a) (long b)) (rt/vlt b a)) Boolean/TRUE Boolean/FALSE))
               (nxt (inc pc) (dec sp)))
          GE (let [b (aget stack (dec sp)) a (aget stack (- sp 2))]
               (aset stack (- sp 2) (if (if (instance? Long a) (>= (long a) (long b)) (rt/vle b a)) Boolean/TRUE Boolean/FALSE))
               (nxt (inc pc) (dec sp)))
          CONCAT_STR (do (aset stack (- sp 2) (concat-str (aget stack (- sp 2)) (aget stack (dec sp))))
                         (nxt (inc pc) (dec sp)))
          CONCAT_LIST (do (aset stack (- sp 2) (concat-list (aget stack (- sp 2)) (aget stack (dec sp))))
                          (nxt (inc pc) (dec sp)))
          JUMP (nxt (aget code (+ pc 1)) sp)
          JUMP_IF_FALSE (if (.booleanValue ^Boolean (aget stack (dec sp)))
                          (nxt (+ pc 2) (dec sp))
                          (nxt (aget code (+ pc 1)) (dec sp)))
          JUMP_IF_TRUE (if (.booleanValue ^Boolean (aget stack (dec sp)))
                         (nxt (aget code (+ pc 1)) (dec sp))
                         (nxt (+ pc 2) (dec sp)))
          MAKE_LIST (let [n (aget code (+ pc 1)) nsp (- sp n)]
                      (aset stack nsp (make-list stack nsp n)) (nxt (+ pc 2) (inc nsp)))
          MAKE_MAP (let [n (aget code (+ pc 1)) nsp (- sp (* 2 n))]
                     (aset stack nsp (make-map stack nsp n)) (nxt (+ pc 2) (inc nsp)))
          MAKE_TUPLE (let [n (aget code (+ pc 1)) nsp (- sp n)]
                       (aset stack nsp (slice-array stack nsp n)) (nxt (+ pc 2) (inc nsp)))
          MAKE_STRUCT (let [n (aget code (+ pc 2)) nsp (- sp n)]
                        (aset stack nsp (Rec. (aget code (+ pc 1)) -1 (slice-array stack nsp n)))
                        (nxt (+ pc 3) (inc nsp)))
          MAKE_ENUM (let [n (aget code (+ pc 3)) nsp (- sp n)]
                      (aset stack nsp (Rec. (aget code (+ pc 1)) (aget code (+ pc 2)) (slice-array stack nsp n)))
                      (nxt (+ pc 4) (inc nsp)))
          GET_FIELD (do (aset stack (dec sp) (aget ^objects (.f ^Rec (aget stack (dec sp))) (aget code (+ pc 1))))
                        (nxt (+ pc 2) sp))
          GET_PAYLOAD (do (aset stack (dec sp) (aget ^objects (.f ^Rec (aget stack (dec sp))) (aget code (+ pc 1))))
                          (nxt (+ pc 2) sp))
          GET_TUPLE (do (aset stack (dec sp) (aget ^objects (aget stack (dec sp)) (aget code (+ pc 1))))
                        (nxt (+ pc 2) sp))
          INDEX_GET (do (aset stack (- sp 2) (index-get (aget stack (- sp 2)) (aget stack (dec sp))))
                        (nxt (inc pc) (dec sp)))
          INDEX_SET (do (index-set (aget stack (- sp 3)) (aget stack (- sp 2)) (aget stack (dec sp)))
                        (nxt (inc pc) (- sp 3)))
          IS_VARIANT (do (aset stack (dec sp)
                               (if (== (.vi ^Rec (aget stack (dec sp))) (aget code (+ pc 1))) Boolean/TRUE Boolean/FALSE))
                         (nxt (+ pc 2) sp))
          SEQ_LEN (do (aset stack (dec sp) (boxl (seq-len (aget stack (dec sp))))) (nxt (inc pc) sp))
          SEQ_GET (do (aset stack (- sp 2) (.get ^ArrayList (aget stack (- sp 2)) (int (long (aget stack (dec sp))))))
                      (nxt (inc pc) (dec sp)))
          LIST_REST (do (aset stack (dec sp) (list-rest (aget stack (dec sp)) (aget code (+ pc 1))))
                        (nxt (+ pc 2) sp))
          NO_MATCH (panic "no match")
          PANIC (panic (rt/str-of (aget stack (dec sp))))
          HALT (do (aset regs 0 (aget frsp fp)) (aset regs 1 0) UNIT)
          SAVE_SP (do (aset stack (+ bp (aget code (+ pc 1))) (boxl (- sp bp))) (nxt (+ pc 2) sp))
          RESTORE_SP (nxt (+ pc 2) (+ bp (long (aget stack (+ bp (aget code (+ pc 1)))))))
          ITER_NEXT
          (let [sq (aget stack (+ bp (aget code (+ pc 1))))
                ixs (+ bp (aget code (+ pc 2)))
                i (long (aget stack ixs))]
            (if (instance? ArrayList sq)
              (if (< i (.size ^ArrayList sq))
                (do (aset stack (+ bp (aget code (+ pc 4))) (.get ^ArrayList sq (int i)))
                    (aset stack ixs (boxl (unchecked-inc i)))
                    (nxt (+ pc 5) sp))
                (nxt (aget code (+ pc 3)) sp))
              (let [^String s (.s ^VStr sq)]
                (if (< i (.length s))
                  (let [cp (.codePointAt s (int i))]
                    (aset stack (+ bp (aget code (+ pc 4))) (Integer/valueOf (int cp)))
                    (aset stack ixs (boxl (+ i (Character/charCount cp))))
                    (nxt (+ pc 5) sp))
                  (nxt (aget code (+ pc 3)) sp)))))
          RANGE_NEXT
          (let [ixs (+ bp (aget code (+ pc 1)))
                i (long (aget stack ixs))
                h (long (aget stack (+ bp (aget code (+ pc 2)))))]
            (if (< i h)
              (do (aset stack (+ bp (aget code (+ pc 4))) (aget stack ixs))
                  (aset stack ixs (boxl (unchecked-inc i)))
                  (nxt (+ pc 5) sp))
              (nxt (aget code (+ pc 3)) sp)))
          (throw (ex-info "bad opcode" {})))))))

(defn run
  "Run compiled program `prog` (from `langvm.compile`), writing program output
  to `out`.  Returns nil on normal completion or the panic message."
  [prog ^java.io.OutputStream out]
  (let [builtins stdlib/impls
        m (Machine. (object-array [(object-array 65536)]) (long-array 2)
                    (long-array (+ max-frames 2)) (long-array (+ max-frames 2)) (long-array (+ max-frames 2))
                    (object-array (+ max-frames 2)) (object-array (+ max-frames 2))
                    (:consts prog) (:code prog) (:nlocals prog)
                    (:impl-table prog) (:ncon prog) builtins)
        result (promise)
        task (bound-fn []
               (deliver result
                        (try
                          (binding [stdlib/*vm-out* out]
                            (exec m (:main prog) nil 0)
                            nil)
                          (catch Throwable e e))))
        thread (Thread. nil task "langvm" (* 1024 1024 1024))]
    (.start thread)
    (.join thread)
    (let [r @result]
      (cond
        (nil? r) nil
        (rt/panic? r) (:langvm/panic (ex-data r))
        (instance? StackOverflowError r) "call stack overflow"
        :else (throw r)))))
