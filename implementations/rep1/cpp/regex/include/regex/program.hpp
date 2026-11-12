#pragma once
/// \file program.hpp
/// Compiled form of a pattern: a small instruction set executed by the
/// backtracking Matcher.

#include <cstdint>
#include <vector>

#include "regex/analysis.hpp"
#include "regex/ast.hpp"

namespace regex {

enum class Op : std::uint8_t {
  Char,         ///< consume byte x
  Set,          ///< consume a byte in sets[x]
  Run,          ///< greedily consume up to y (-1: any number of) bytes in sets[x];
                ///< backtracking gives them back one at a time
  AssertBegin,  ///< succeed only at offset 0
  AssertEnd,    ///< succeed only at the end of the subject
  Split,        ///< continue at x; on failure resume at y
  Jump,         ///< continue at x
  SetReg,       ///< regs[x] = current offset (undone on backtracking)
  CheckEmpty,   ///< if current offset == regs[x] continue at y, else fall through
  Match         ///< success
};

struct Inst {
  Op op;
  std::int32_t x = 0;
  std::int32_t y = 0;
};

/// Registers 2*(g-1) and 2*(g-1)+1 hold the start and end of capture group g;
/// registers from 2*group_count upwards are loop bookkeeping.
struct Program {
  std::vector<Inst> code;
  std::vector<CharSet> sets;
  int group_count = 0;
  int reg_count = 0;
  StartInfo start;
};

/// Upper bound on the number of instructions; bigger patterns (after
/// expanding counted quantifiers) are rejected with Error.
inline constexpr std::size_t kMaxProgramSize = 2'000'000;

/// Compiles a syntax tree. Throws Error if the program would be too large.
Program compile(const Node& root, int group_count);

}  // namespace regex
