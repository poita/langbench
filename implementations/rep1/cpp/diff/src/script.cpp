#include "mdiff/script.hpp"

namespace mdiff {

std::size_t script_cost(const EditScript& script) {
  std::size_t c = 0;
  for (const Edit& e : script)
    if (e.kind != EditKind::Keep) ++c;
  return c;
}

std::string render_script(const EditScript& script, const Lines& a, const Lines& b) {
  std::string out;
  for (const Edit& e : script) {
    out.push_back(static_cast<char>(e.kind));
    const Line text = e.kind == EditKind::Insert ? b[e.index] : a[e.index];
    out.append(text);
    out.push_back('\n');
  }
  return out;
}

ScriptLine parse_script_line(Line line) {
  if (line.empty()) throw ScriptError("empty script line");
  switch (line[0]) {
    case ' ': return {EditKind::Keep, line.substr(1)};
    case '-': return {EditKind::Delete, line.substr(1)};
    case '+': return {EditKind::Insert, line.substr(1)};
    default: throw ScriptError("invalid script tag");
  }
}

}  // namespace mdiff
