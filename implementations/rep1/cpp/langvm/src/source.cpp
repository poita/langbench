#include "source.h"

#include <set>
#include <unordered_map>

#include "langvm/diagnostic.h"
#include "utf8.h"

namespace langvm {

bool isKeyword(std::string_view s) {
  static const std::set<std::string_view> kws = {
      "as",   "break",  "continue", "else",  "enum",   "false", "fn",   "for",
      "if",   "impl",   "in",       "let",   "match",  "pub",   "return", "self",
      "struct", "trait", "true",    "use",   "var",    "when",  "while"};
  return kws.count(s) != 0;
}

bool isIdentifier(std::string_view s) {
  if (s.empty() || s.size() > 200) return false;
  auto alpha = [](char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; };
  if (!alpha(s[0])) return false;
  for (char c : s)
    if (!alpha(c) && !(c >= '0' && c <= '9')) return false;
  if (s == "_") return false;
  return !isKeyword(s);
}

std::vector<ModuleSource> splitModules(std::string_view input) {
  // Split into lines.
  std::vector<std::string_view> lines;
  size_t start = 0;
  while (start < input.size()) {
    size_t nl = input.find('\n', start);
    size_t end = nl == std::string_view::npos ? input.size() : nl;
    std::string_view line = input.substr(start, end - start);
    if (nl != std::string_view::npos && !line.empty() && line.back() == '\r') line.remove_suffix(1);
    lines.push_back(line);
    if (nl == std::string_view::npos) break;
    start = nl + 1;
  }
  constexpr std::string_view kPrefix = "@module ";
  auto headerName = [&](std::string_view line, std::string& name) {
    if (line.substr(0, kPrefix.size()) != kPrefix) return false;
    std::string_view rest = line.substr(kPrefix.size());
    if (!isIdentifier(rest)) return false;
    name = std::string(rest);
    return true;
  };

  if (lines.empty()) throw CompileError(ErrorKind::BadModule, 1, 1);
  std::vector<ModuleSource> modules;
  std::vector<std::u32string> bodyLines;
  std::unordered_map<std::string, int> seen;
  int dupLine = 0;
  std::vector<std::vector<std::string_view>> bodies;
  std::vector<std::string> names;
  for (size_t i = 0; i < lines.size(); ++i) {
    std::string name;
    if (headerName(lines[i], name)) {
      if (seen.count(name) && dupLine == 0) dupLine = static_cast<int>(i) + 1;
      seen.emplace(name, static_cast<int>(i));
      names.push_back(name);
      bodies.emplace_back();
    } else if (i == 0 || (!lines[i].empty() && lines[i][0] == '@')) {
      throw CompileError(ErrorKind::BadModule, static_cast<int>(i) + 1, 1);
    } else {
      bodies.back().push_back(lines[i]);
    }
  }
  if (dupLine) throw CompileError(ErrorKind::DupModule, dupLine, 1);
  for (size_t m = 0; m < names.size(); ++m) {
    std::string body;
    for (size_t k = 0; k < bodies[m].size(); ++k) {
      if (k) body.push_back('\n');
      body.append(bodies[m][k]);
    }
    modules.push_back({names[m], decodeUtf8(body)});
  }
  return modules;
}

}  // namespace langvm
