// The instruction set and the compiled program (SPEC.md section 16).
#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "langvm/langvm.h"
#include "value.h"

namespace langvm {

enum class Op16 : uint16_t {
  PUSH_CONST, PUSH_TRUE, PUSH_FALSE, PUSH_UNIT,
  LOAD_LOCAL, STORE_LOCAL, LOAD_UPVAL, POP, POPN,
  MAKE_CLOSURE, CALL, CALL_VALUE, CALL_BUILTIN, CALL_METHOD, RET, RET_UNIT,
  ADD_I, SUB_I, MUL_I, DIV_I, MOD_I, NEG_I, BNOT, BAND, BOR, BXOR, SHL, SHR,
  ADD_F, SUB_F, MUL_F, DIV_F, NEG_F, NOT_B,
  EQ, NE, LT, LE, GT, GE, CONCAT,
  JUMP, JUMP_IF_FALSE, JUMP_IF_TRUE,
  MAKE_LIST, MAKE_MAP, MAKE_TUPLE, MAKE_STRUCT, MAKE_ENUM,
  GET_FIELD, GET_PAYLOAD, GET_TUPLE, INDEX_GET, INDEX_SET,
  IS_VARIANT, SEQ_LEN, LIST_REST, NO_MATCH, HALT
};

// Operands: a, b are 32-bit; c a 16-bit count (argument / payload counts).
struct Instr {
  Op16 op;
  uint16_t c = 0;
  int32_t a = 0;
  int32_t b = 0;
};

struct CompiledFunction {
  std::string name;
  int nparams = 0;
  int nlocals = 0;
  int maxStack = 0;
  std::vector<Instr> code;
};

// Everything the VM needs, hidden behind the public Program handle.
struct Program::Impl {
  std::vector<Value> consts;
  std::vector<CompiledFunction> funcs;
  // (trait, head constructor) -> function index per trait method.
  std::unordered_map<unsigned long long, std::vector<int>> impls;
  int mainFunc = -1;
};

}  // namespace langvm
