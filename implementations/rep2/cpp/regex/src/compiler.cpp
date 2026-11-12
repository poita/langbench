#include "rx/program.hpp"

#include "rx/error.hpp"

namespace rx {
namespace {

// Adds to `out` the characters that can start a match of `n`; returns whether
// `n` can match without consuming anything.
bool first_chars(const Node& n, CharSet& out) {
  switch (n.kind) {
    case NodeKind::Literal: out.add(n.ch); return false;
    case NodeKind::Any: {
      CharSet all;
      all.invert();
      out.add_all(all);
      return false;
    }
    case NodeKind::Set: out.add_all(n.set); return false;
    case NodeKind::Empty: case NodeKind::Bol: case NodeKind::Eol: return true;
    case NodeKind::Concat:
      for (auto& c : n.children)
        if (!first_chars(*c, out)) return false;
      return true;
    case NodeKind::Alternate: {
      bool nullable = false;
      for (auto& c : n.children) nullable |= first_chars(*c, out);
      return nullable;
    }
    case NodeKind::Group: return first_chars(*n.children[0], out);
    case NodeKind::Repeat:
      if (n.max == 0) return true;  // the atom never runs
      return first_chars(*n.children[0], out) || n.min == 0;
  }
  return true;
}

// True if every successful match of `n` must have matched at position 0,
// because it necessarily passes through a '^'.
bool anchored(const Node& n) {
  switch (n.kind) {
    case NodeKind::Bol: return true;
    case NodeKind::Concat:
      for (auto& c : n.children)
        if (anchored(*c)) return true;
      return false;
    case NodeKind::Alternate:
      for (auto& c : n.children)
        if (!anchored(*c)) return false;
      return true;
    case NodeKind::Group: return anchored(*n.children[0]);
    case NodeKind::Repeat: return n.min >= 1 && anchored(*n.children[0]);
    default: return false;
  }
}

class Compiler {
 public:
  Program run(const ParsedPattern& pat) {
    prog_.group_count = pat.group_count;
    next_reg_ = 3 * pat.group_count;
    emit(*pat.root);
    add(Op::Match);
    prog_.reg_count = next_reg_;
    prog_.anchored_start = anchored(*pat.root);
    CharSet first;
    prog_.use_first_filter = !first_chars(*pat.root, first);
    prog_.first = first;
    return std::move(prog_);
  }

 private:
  std::size_t here() const { return prog_.code.size(); }

  std::size_t add(Op op, std::int32_t a = 0, std::int32_t b = 0) {
    if (prog_.code.size() >= kMaxProgramSize) throw Error("pattern expands to too many instructions");
    prog_.code.push_back(Inst{op, a, b});
    return prog_.code.size() - 1;
  }

  std::int32_t pc(std::size_t v) const { return static_cast<std::int32_t>(v); }

  void emit(const Node& n) {
    switch (n.kind) {
      case NodeKind::Empty: break;
      case NodeKind::Literal: add(Op::Char, n.ch); break;
      case NodeKind::Any: add(Op::Any); break;
      case NodeKind::Set:
        prog_.sets.push_back(n.set);
        add(Op::Set, static_cast<std::int32_t>(prog_.sets.size() - 1));
        break;
      case NodeKind::Bol: add(Op::Bol); break;
      case NodeKind::Eol: add(Op::Eol); break;
      case NodeKind::Concat:
        for (auto& c : n.children) emit(*c);
        break;
      case NodeKind::Alternate: emit_alternate(n); break;
      case NodeKind::Group: {
        auto base = static_cast<std::int32_t>(3 * (n.group - 1));
        add(Op::Open, base);
        emit(*n.children[0]);
        add(Op::Close, base);
        break;
      }
      case NodeKind::Repeat: emit_repeat(n); break;
    }
  }

  void emit_alternate(const Node& n) {
    std::vector<std::size_t> jumps;
    for (std::size_t i = 0; i < n.children.size(); ++i) {
      if (i + 1 == n.children.size()) {
        emit(*n.children[i]);
        break;
      }
      std::size_t split = add(Op::Split);
      prog_.code[split].a = pc(here());
      emit(*n.children[i]);
      jumps.push_back(add(Op::Jmp));
      prog_.code[split].b = pc(here());
    }
    for (auto j : jumps) prog_.code[j].a = pc(here());
  }

  // x{min,max}: `min` mandatory copies, then either a greedy loop (unbounded)
  // or a chain of nested optional copies. An optional iteration that matches
  // the empty string jumps straight to the end of the whole repetition.
  void emit_repeat(const Node& n) {
    const Node& atom = *n.children[0];
    if (n.max == 0) return;
    for (int i = 0; i < n.min; ++i) emit(atom);
    const bool guard = atom.nullable;  // only nullable atoms can iterate emptily
    if (n.max == Node::kUnbounded) {
      std::size_t loop = add(Op::Split);
      prog_.code[loop].a = pc(here());
      std::int32_t mark = guard ? new_reg() : 0;
      if (guard) add(Op::Mark, mark);
      emit(atom);
      std::size_t check = guard ? add(Op::CheckEmpty, mark) : 0;
      add(Op::Jmp, pc(loop));
      std::int32_t end = pc(here());
      prog_.code[loop].b = end;
      if (guard) prog_.code[check].b = end;
      return;
    }
    std::vector<std::size_t> to_end;  // instructions whose target is the end
    for (int i = n.min; i < n.max; ++i) {
      std::size_t split = add(Op::Split);
      prog_.code[split].a = pc(here());
      to_end.push_back(split);
      const bool last = i + 1 == n.max;
      std::int32_t mark = (guard && !last) ? new_reg() : 0;
      if (guard && !last) add(Op::Mark, mark);
      emit(atom);
      if (guard && !last) to_end.push_back(add(Op::CheckEmpty, mark));
    }
    std::int32_t end = pc(here());
    for (auto i : to_end) prog_.code[i].b = end;
  }

  std::int32_t new_reg() { return static_cast<std::int32_t>(next_reg_++); }

  Program prog_;
  std::size_t next_reg_ = 0;
};

}  // namespace

Program compile(const ParsedPattern& pattern) { return Compiler().run(pattern); }

}  // namespace rx
