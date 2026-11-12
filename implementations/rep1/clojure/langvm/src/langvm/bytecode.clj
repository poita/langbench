(ns langvm.bytecode
  "The instruction set (SPEC 16.2, with a few fused additions).

  Every instruction is an opcode followed by a fixed number of integer
  operands, stored inline in an `int[]`.  `op-codes` maps an instruction name
  to its number and `op-width` to the number of operands; [[opcase]] is a
  `case` over opcodes written with the instruction names.")

(def instructions
  "[name operand-count] in opcode order."
  '[[PUSH_CONST 1] [PUSH_TRUE 0] [PUSH_FALSE 0] [PUSH_UNIT 0]
    [LOAD_LOCAL 1] [STORE_LOCAL 1] [LOAD_UPVAL 1] [POP 0] [DUP 0]
    [MAKE_CLOSURE 2] [CALL 2] [CALL_VALUE 1] [CALL_BUILTIN 2] [CALL_METHOD 3]
    [RET 0] [RET_UNIT 0]
    [ADD_I 0] [SUB_I 0] [MUL_I 0] [DIV_I 0] [MOD_I 0] [NEG_I 0] [BNOT 0]
    [BAND 0] [BOR 0] [BXOR 0] [SHL 0] [SHR 0]
    [ADD_F 0] [SUB_F 0] [MUL_F 0] [DIV_F 0] [NEG_F 0] [NOT_B 0]
    [EQ 0] [NE 0] [LT 0] [LE 0] [GT 0] [GE 0]
    [CONCAT_STR 0] [CONCAT_LIST 0]
    [JUMP 1] [JUMP_IF_FALSE 1] [JUMP_IF_TRUE 1]
    [MAKE_LIST 1] [MAKE_MAP 1] [MAKE_TUPLE 1] [MAKE_STRUCT 2] [MAKE_ENUM 3]
    [GET_FIELD 1] [GET_PAYLOAD 1] [GET_TUPLE 1]
    [INDEX_GET 0] [INDEX_SET 0]
    [IS_VARIANT 1] [SEQ_LEN 0] [SEQ_GET 0] [LIST_REST 1]
    [NO_MATCH 0] [PANIC 0] [HALT 0]
    ;; additions: loop support (SAVE_SP/RESTORE_SP reset the expression stack on
    ;; break/continue; ITER_NEXT/RANGE_NEXT fuse the loop test and the fetch)
    [SAVE_SP 1] [RESTORE_SP 1]
    [ITER_NEXT 4]        ; seq-slot idx-slot end-target dst-slot
    [RANGE_NEXT 4]       ; idx-slot hi-slot end-target dst-slot
    ])

(def op-codes
  (into {} (map-indexed (fn [i [n _]] [n i]) instructions)))

(def op-width
  (int-array (map second instructions)))

(defmacro opcase
  "`(opcase op NAME body ... default)`: `case` on an opcode with instruction
  names as the test constants."
  [expr & clauses]
  (let [default (when (odd? (count clauses)) (last clauses))
        pairs (partition 2 (if default (butlast clauses) clauses))]
    `(case ~expr
       ~@(mapcat (fn [[n body]]
                   (let [c (get op-codes n)]
                     (assert c (str "unknown opcode " n))
                     [c body]))
                 pairs)
       ~@(when default [default]))))

(def ^:private kw-codes
  (into {} (map (fn [[n c]] [(keyword (name n)) c])) op-codes))

(defn op
  "Numeric opcode for instruction keyword `n` (e.g. `:PUSH_CONST`)."
  ^long [n]
  (long (get kw-codes n)))
