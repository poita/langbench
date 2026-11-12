#include <unordered_map>

#include "regex/error.hpp"
#include "regex/program.hpp"

namespace regex {
namespace {

class Compiler {
 public:
  explicit Compiler(int groups) { prog_.group_count = groups; prog_.reg_count = 2 * groups; }

  Program run(const Node& root) {
    emit(root);
    add({Op::Match});
    prog_.start = analyze_start(root);
    return std::move(prog_);
  }

 private:
  int pc() const { return static_cast<int>(prog_.code.size()); }

  int add(Inst i) {
    if (prog_.code.size() >= kMaxProgramSize) throw Error("pattern is too large after expanding repeats");
    prog_.code.push_back(i);
    return pc() - 1;
  }

  int set_index(const Node& n) {
    auto it = set_ids_.find(&n);
    if (it != set_ids_.end()) return it->second;
    prog_.sets.push_back(n.set);
    int id = static_cast<int>(prog_.sets.size()) - 1;
    set_ids_.emplace(&n, id);
    return id;
  }

  static bool single_char(const Node& n) {
    return n.kind == NodeKind::Literal || n.kind == NodeKind::Set;
  }

  void emit_single(const Node& n) {
    if (n.kind == NodeKind::Literal) add({Op::Char, n.ch, 0});
    else add({Op::Set, set_index(n), 0});
  }

  void emit(const Node& n) {
    switch (n.kind) {
      case NodeKind::Literal:
      case NodeKind::Set: emit_single(n); break;
      case NodeKind::AssertBegin: add({Op::AssertBegin}); break;
      case NodeKind::AssertEnd: add({Op::AssertEnd}); break;
      case NodeKind::Concat:
        for (const auto& c : n.children) emit(*c);
        break;
      case NodeKind::Alternate: emit_alternate(n); break;
      case NodeKind::Group:
        add({Op::SetReg, 2 * (n.group - 1), 0});
        emit(*n.children[0]);
        add({Op::SetReg, 2 * (n.group - 1) + 1, 0});
        break;
      case NodeKind::Repeat: emit_repeat(n); break;
    }
  }

  void emit_alternate(const Node& n) {
    std::vector<int> jumps;
    for (std::size_t i = 0; i < n.children.size(); ++i) {
      bool last = i + 1 == n.children.size();
      int split = -1;
      if (!last) split = add({Op::Split, 0, 0});
      if (!last) prog_.code[split].x = pc();
      emit(*n.children[i]);
      if (!last) {
        jumps.push_back(add({Op::Jump, 0, 0}));
        prog_.code[split].y = pc();
      }
    }
    for (int j : jumps) prog_.code[j].x = pc();
  }

  void emit_repeat(const Node& n) {
    const Node& atom = *n.children[0];
    if (n.max == 0) return;  // never runs the atom (groups stay unset)
    for (int i = 0; i < n.min; ++i) emit(atom);

    if (single_char(atom)) {
      if (n.max == kUnbounded) {
        add({Op::Run, set_of(atom), -1});
      } else if (n.max > n.min) {
        add({Op::Run, set_of(atom), n.max - n.min});
      }
      return;
    }

    // General atom: optional iterations, each of which ends the repetition
    // if it consumed nothing (SPEC section 3).
    bool check = can_match_empty(atom);
    int reg = -1;
    if (check) reg = prog_.reg_count++;
    std::vector<int> exits;  // instructions whose exit target is the end
    auto iteration = [&]() {
      if (check) add({Op::SetReg, reg, 0});
      emit(atom);
      if (check) exits.push_back(add({Op::CheckEmpty, reg, 0}));
    };

    if (n.max == kUnbounded) {
      int loop = add({Op::Split, 0, 0});
      prog_.code[loop].x = pc();
      iteration();
      add({Op::Jump, loop, 0});
      exits.push_back(-loop - 1);  // Split's second target
    } else {
      for (int i = n.min; i < n.max; ++i) {
        int split = add({Op::Split, 0, 0});
        prog_.code[split].x = pc();
        exits.push_back(-split - 1);
        iteration();
      }
    }
    int end = pc();
    for (int e : exits) {
      if (e >= 0) prog_.code[e].y = end;
      else prog_.code[-e - 1].y = end;
    }
  }

  int set_of(const Node& n) {
    if (n.kind == NodeKind::Set) return set_index(n);
    // A literal: give it a one-element set.
    auto it = set_ids_.find(&n);
    if (it != set_ids_.end()) return it->second;
    prog_.sets.push_back(CharSet::single(n.ch));
    int id = static_cast<int>(prog_.sets.size()) - 1;
    set_ids_.emplace(&n, id);
    return id;
  }

  Program prog_;
  std::unordered_map<const Node*, int> set_ids_;
};

}  // namespace

Program compile(const Node& root, int group_count) { return Compiler(group_count).run(root); }

}  // namespace regex
