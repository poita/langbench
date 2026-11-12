#include "regex/matcher.hpp"

#include <algorithm>
#include <limits>

#include "regex/error.hpp"

namespace regex {
namespace {
enum FrameKind : std::int32_t {
  kBranch,  // resume at pc with offset a
  kUndo,    // regs[a] = b
  kRun      // a Run instruction: resume at pc with offset b, shrinking down to a
};
constexpr std::int32_t kUnset = -1;
}  // namespace

Matcher::Matcher(const Program& program) : prog_(&program), regs_(program.reg_count, kUnset) {}

bool Matcher::run(const char* s, int n, int start, int& end) {
  const Inst* code = prog_->code.data();
  const CharSet* sets = prog_->sets.data();
  std::int32_t* regs = regs_.data();
  auto& stack = stack_;
  stack.clear();
  int pc = 0;
  int pos = start;

  for (;;) {
    const Inst& in = code[pc];
    switch (in.op) {
      case Op::Char:
        if (pos < n && static_cast<unsigned char>(s[pos]) == in.x) { ++pos; ++pc; continue; }
        break;
      case Op::Set:
        if (pos < n && sets[in.x].contains(static_cast<unsigned char>(s[pos]))) { ++pos; ++pc; continue; }
        break;
      case Op::Run: {
        const CharSet& cs = sets[in.x];
        int limit = (in.y < 0 || in.y > n - pos) ? n : pos + in.y;
        int e = pos;
        while (e < limit && cs.contains(static_cast<unsigned char>(s[e]))) ++e;
        if (e > pos) stack.push_back({kRun, pc + 1, pos, e - 1});
        pos = e;
        ++pc;
        continue;
      }
      case Op::AssertBegin:
        if (pos == 0) { ++pc; continue; }
        break;
      case Op::AssertEnd:
        if (pos == n) { ++pc; continue; }
        break;
      case Op::Split:
        stack.push_back({kBranch, in.y, pos, 0});
        pc = in.x;
        continue;
      case Op::Jump: pc = in.x; continue;
      case Op::SetReg:
        stack.push_back({kUndo, 0, in.x, regs[in.x]});
        regs[in.x] = pos;
        ++pc;
        continue;
      case Op::CheckEmpty:
        pc = (pos == regs[in.x]) ? in.y : pc + 1;
        continue;
      case Op::Match:
        end = pos;
        return true;
    }

    // Failure: unwind to the most recent choice point.
    for (;;) {
      if (stack.empty()) return false;
      Frame& f = stack.back();
      if (f.kind == kUndo) {
        regs[f.a] = f.b;
        stack.pop_back();
      } else if (f.kind == kBranch) {
        pc = f.pc;
        pos = f.a;
        stack.pop_back();
        break;
      } else {  // kRun
        pc = f.pc;
        pos = f.b;
        if (f.b > f.a) --f.b;
        else stack.pop_back();
        break;
      }
    }
  }
}

bool Matcher::search(std::string_view subject, Match& out) {
  if (subject.size() > static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max() - 1))
    throw Error("subject is too long");
  const int n = static_cast<int>(subject.size());
  const char* s = subject.data();
  const StartInfo& info = prog_->start;

  // Only the capture registers need resetting: loop registers are always
  // written before they are read, and a failed attempt unwinds every write,
  // so the captures stay unset between start positions.
  std::fill(regs_.begin(), regs_.begin() + 2 * prog_->group_count, kUnset);

  int start = 0;
  for (;;) {
    if (!info.nullable) {
      while (start < n && !info.first.contains(static_cast<unsigned char>(s[start]))) ++start;
      if (start >= n) return false;  // a match must consume a character
    }
    if (info.anchored && start != 0) return false;
    int end;
    if (run(s, n, start, end)) {
      out.span = {static_cast<std::size_t>(start), static_cast<std::size_t>(end)};
      out.groups.resize(prog_->group_count);
      for (int g = 0; g < prog_->group_count; ++g) {
        std::int32_t b = regs_[2 * g], e = regs_[2 * g + 1];
        if (b >= 0 && e >= 0) out.groups[g] = Span{static_cast<std::size_t>(b), static_cast<std::size_t>(e)};
        else out.groups[g].reset();
      }
      return true;
    }
    if (++start > n) return false;
  }
}

}  // namespace regex
