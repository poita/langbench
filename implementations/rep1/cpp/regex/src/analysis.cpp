#include "regex/analysis.hpp"

namespace regex {
namespace {

// Adds the possible first characters of `n` to `out`; returns whether `n`
// can match the empty string (conservatively: assertions count as empty).
bool first_set(const Node& n, CharSet& out) {
  switch (n.kind) {
    case NodeKind::Literal: out.add(n.ch); return false;
    case NodeKind::Set: out.add_all(n.set); return false;
    case NodeKind::AssertBegin:
    case NodeKind::AssertEnd: return true;
    case NodeKind::Concat:
      for (const auto& c : n.children)
        if (!first_set(*c, out)) return false;
      return true;
    case NodeKind::Alternate: {
      bool nullable = false;
      for (const auto& c : n.children) nullable |= first_set(*c, out);
      return nullable;
    }
    case NodeKind::Group: return first_set(*n.children[0], out);
    case NodeKind::Repeat:
      if (n.max == 0) return true;  // the atom never runs
      return first_set(*n.children[0], out) || n.min == 0;
  }
  return true;
}

bool anchored(const Node& n) {
  switch (n.kind) {
    case NodeKind::AssertBegin: return true;
    case NodeKind::Concat: return !n.children.empty() && anchored(*n.children[0]);
    case NodeKind::Alternate:
      for (const auto& c : n.children)
        if (!anchored(*c)) return false;
      return true;
    case NodeKind::Group: return anchored(*n.children[0]);
    case NodeKind::Repeat: return n.min >= 1 && anchored(*n.children[0]);
    default: return false;
  }
}

}  // namespace

bool can_match_empty(const Node& n) {
  CharSet ignored;
  return first_set(n, ignored);
}

StartInfo analyze_start(const Node& root) {
  StartInfo info;
  info.nullable = first_set(root, info.first);
  info.anchored = anchored(root);
  return info;
}

}  // namespace regex
