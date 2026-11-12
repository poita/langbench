#include "rx/matcher.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace rx {

Matcher::Matcher(const Program& program)
    : prog_(&program), regs_(program.reg_count, -1) {
  stack_.reserve(1024);
}

// Executes the program from `start`. Capture and loop-mark writes are logged
// on the stack so that backtracking restores them: the log costs one entry per
// write, and a failed run leaves every register exactly as it found it.
bool Matcher::run(const char* s, std::int32_t len, std::int32_t start, std::int32_t& end) {
  const Inst* code = prog_->code.data();
  const CharSet* sets = prog_->sets.data();
  std::int32_t* regs = regs_.data();
  stack_.clear();

  std::int32_t pc = 0;
  std::int32_t pos = start;
  for (;;) {
    const Inst& in = code[pc];
    switch (in.op) {
      case Op::Char:
        if (pos < len && static_cast<unsigned char>(s[pos]) == in.a) { ++pos; ++pc; continue; }
        break;
      case Op::Any:
        if (pos < len) { ++pos; ++pc; continue; }
        break;
      case Op::Set:
        if (pos < len && sets[in.a].contains(static_cast<unsigned char>(s[pos]))) { ++pos; ++pc; continue; }
        break;
      case Op::Bol:
        if (pos == 0) { ++pc; continue; }
        break;
      case Op::Eol:
        if (pos == len) { ++pc; continue; }
        break;
      case Op::Split:
        stack_.push_back({in.b, pos});
        pc = in.a;
        continue;
      case Op::Jmp:
        pc = in.a;
        continue;
      case Op::Open:
      case Op::Mark:
        stack_.push_back({~in.a, regs[in.a]});
        regs[in.a] = pos;
        ++pc;
        continue;
      case Op::Close:
        stack_.push_back({~(in.a + 1), regs[in.a + 1]});
        stack_.push_back({~(in.a + 2), regs[in.a + 2]});
        regs[in.a + 1] = regs[in.a];
        regs[in.a + 2] = pos;
        ++pc;
        continue;
      case Op::CheckEmpty:
        pc = (regs[in.a] == pos) ? in.b : pc + 1;
        continue;
      case Op::Match:
        end = pos;
        return true;
    }
    // Failure: unwind to the most recent choice point.
    for (;;) {
      if (stack_.empty()) return false;
      Entry e = stack_.back();
      stack_.pop_back();
      if (e.tag < 0) {
        regs[~e.tag] = e.value;
      } else {
        pc = e.tag;
        pos = e.value;
        break;
      }
    }
  }
}

bool Matcher::search(std::string_view subject, Match& out) {
  if (subject.size() > static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max()))
    throw std::length_error("subject too long");
  const Program& P = *prog_;
  const auto len = static_cast<std::int32_t>(subject.size());
  const char* s = subject.data();
  const std::size_t ncap = 3 * P.group_count;

  for (std::int32_t start = 0; start <= len; ++start) {
    if (P.anchored_start && start > 0) break;
    if (P.use_first_filter) {
      if (start == len) break;  // a non-nullable pattern cannot match here
      if (!P.first.contains(static_cast<unsigned char>(s[start]))) continue;
    }
    std::int32_t end = 0;
    if (run(s, len, start, end)) {
      out.begin = static_cast<std::size_t>(start);
      out.end = static_cast<std::size_t>(end);
      out.groups.resize(P.group_count);
      for (std::size_t g = 0; g < P.group_count; ++g) {
        std::int32_t b = regs_[3 * g + 1], e = regs_[3 * g + 2];
        out.groups[g] = b < 0 ? Span{} : Span{static_cast<std::size_t>(b), static_cast<std::size_t>(e)};
      }
      std::fill(regs_.begin(), regs_.begin() + static_cast<std::ptrdiff_t>(ncap), -1);
      return true;
    }
  }
  return false;
}

}  // namespace rx
