// Compiled form of a pattern: a flat instruction list for the backtracking VM.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "rx/ast.hpp"
#include "rx/charset.hpp"

namespace rx {

enum class Op : std::uint8_t {
  Char,        ///< consume the character `a`
  Any,         ///< consume any character
  Set,         ///< consume a character that is in sets[a]
  Bol,         ///< succeed at position 0
  Eol,         ///< succeed at end of subject
  Split,       ///< try pc `a` first; on failure resume at pc `b`
  Jmp,         ///< continue at pc `a`
  Open,        ///< regs[a] = pos                         (group start, in flight)
  Close,       ///< regs[a+1] = regs[a]; regs[a+2] = pos  (group completed)
  Mark,        ///< regs[a] = pos                         (start of a loop iteration)
  CheckEmpty,  ///< if regs[a] == pos continue at pc `b` (empty iteration ends the loop)
  Match,       ///< overall success
};

struct Inst {
  Op op;
  std::int32_t a = 0;
  std::int32_t b = 0;
};

/// Immutable result of compilation; shared by any number of Matchers.
struct Program {
  std::vector<Inst> code;
  std::vector<CharSet> sets;
  std::size_t group_count = 0;
  /// Register file size. Group g (1-based) owns regs [3(g-1), 3(g-1)+2]:
  /// in-flight start, completed start, completed end. Loop marks follow.
  std::size_t reg_count = 0;
  /// True if every match must begin at position 0.
  bool anchored_start = false;
  /// If set, a match can only begin at a position whose character is in
  /// `first`, and cannot begin at end of subject. Unset if the pattern can
  /// match the empty string.
  bool use_first_filter = false;
  CharSet first;
};

/// Largest number of instructions a pattern may expand to.
constexpr std::size_t kMaxProgramSize = 2'000'000;

/// Compiles a syntax tree. Counted quantifiers are expanded into copies.
/// \throws Error if the expansion exceeds kMaxProgramSize.
Program compile(const ParsedPattern& pattern);

}  // namespace rx
