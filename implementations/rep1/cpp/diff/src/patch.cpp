#include "mdiff/patch.hpp"

namespace mdiff {

Lines apply_script(const Lines& a, const Lines& script_lines) {
  Lines out;
  out.reserve(script_lines.size());
  std::size_t next = 0;  // next unconsumed line of A
  for (Line raw : script_lines) {
    const ScriptLine s = parse_script_line(raw);
    if (s.kind != EditKind::Insert) {
      if (next >= a.size()) throw ScriptError("script consumes more lines than A has");
      if (a[next] != s.text) throw ScriptError("script line does not match A");
      ++next;
    }
    if (s.kind != EditKind::Delete) out.push_back(s.text);
  }
  if (next != a.size()) throw ScriptError("script does not consume all of A");
  return out;
}

}  // namespace mdiff
