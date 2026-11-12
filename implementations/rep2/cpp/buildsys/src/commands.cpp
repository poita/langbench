#include "kiln/commands.hpp"

#include <algorithm>
#include <unordered_set>

#include "kiln/error.hpp"
#include "kiln/hash.hpp"
#include "kiln/path.hpp"

namespace kiln {

namespace {

const std::vector<CommandInfo>& commandTable() {
  static const std::vector<CommandInfo> table = {
      {"write", 0, 0, false, 1, {ArgType::Str}},
      {"copy", 1, 1, false, 1, {}},
      {"concat", 1, -1, false, 2, {}},
      {"upper", 1, 1, false, 2, {}},
      {"lower", 1, 1, false, 2, {}},
      {"grep", 1, 1, false, 3, {ArgType::Str}},
      {"replace", 1, 1, false, 3, {ArgType::Str, ArgType::Str}},
      {"sort_lines", 1, 1, false, 4, {}},
      {"reverse_lines", 1, 1, false, 2, {}},
      {"dedup", 1, 1, false, 3, {}},
      {"number", 1, 1, false, 2, {}},
      {"indent", 1, 1, false, 2, {ArgType::Int}},
      {"wrap", 1, 1, false, 1, {ArgType::Str, ArgType::Str}},
      {"count_lines", 1, -1, false, 2, {}},
      {"hash", 1, -1, false, 3, {}},
      {"preprocess", 1, 1, true, 6, {}},
  };
  return table;
}

void appendEscaped(std::string& out, const std::string& s) {
  static const char* hex = "0123456789abcdef";
  out += '"';
  for (unsigned char c : s) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '"': out += "\\\""; break;
      case '\n': out += "\\n"; break;
      case '\t': out += "\\t"; break;
      case '\r': out += "\\r"; break;
      default:
        if (c < 0x20 || c == 0x7f) {
          out += "\\x";
          out += hex[c >> 4];
          out += hex[c & 15];
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  out += '"';
}

std::string replaceAll(std::string_view s, std::string_view from, std::string_view to) {
  std::string out;
  out.reserve(s.size());
  std::size_t i = 0;
  while (i < s.size()) {
    std::size_t j = s.find(from, i);
    if (j == std::string_view::npos) break;
    out.append(s.substr(i, j - i));
    out.append(to);
    i = j + from.size();
  }
  out.append(s.substr(i));
  return out;
}

void emitLine(std::string& out, std::string_view line) {
  out.append(line);
  out += '\n';
}

struct Preprocessor {
  const Vfs& vfs;
  std::string output;
  std::unordered_set<std::string> stack;
  std::vector<std::string> discovered;
  std::unordered_set<std::string> discoveredSet;

  void expand(const std::string& path, const Content& content) {
    stack.insert(path);
    for (std::string_view line : splitLines(*content)) {
      if (line.size() > 6 && line.substr(0, 6) == "@need ") {
        std::string q(line.substr(6));
        if (!isWorkspacePath(q)) throw Error("E_NEED_PATH", q);
        Content c = vfs.read(q);
        if (!c) throw Error("E_NEED_MISSING", q + " needed by " + path);
        if (stack.count(q)) throw Error("E_NEED_CYCLE", q);
        if (discoveredSet.insert(q).second) discovered.push_back(q);
        expand(q, c);
      } else {
        emitLine(output, line);
      }
    }
    stack.erase(path);
  }
};

}  // namespace

std::vector<std::string_view> splitLines(std::string_view content) {
  std::vector<std::string_view> lines;
  std::size_t i = 0;
  while (i < content.size()) {
    std::size_t nl = content.find('\n', i);
    if (nl == std::string_view::npos) {
      lines.push_back(content.substr(i));
      break;
    }
    lines.push_back(content.substr(i, nl - i));
    i = nl + 1;
  }
  return lines;
}

const CommandInfo* findCommand(std::string_view name) {
  for (const auto& c : commandTable())
    if (name == c.name) return &c;
  return nullptr;
}

std::string canonicalCommand(const CommandCall& call) {
  std::string s = call.name;
  s += '(';
  for (std::size_t i = 0; i < call.args.size(); ++i) {
    if (i) s += ", ";
    const Value& v = call.args[i];
    if (v.isInt()) s += std::to_string(v.asInt());
    else appendEscaped(s, v.asStr());
  }
  s += ')';
  return s;
}

CommandResult runCommand(const Step& step, const std::vector<Content>& inputs, const Vfs& vfs) {
  const std::string& name = step.call.name;
  const auto& args = step.call.args;
  CommandResult r;
  std::string& out = r.output;

  if (name == "write") {
    out = args[0].asStr();
  } else if (name == "copy") {
    out = *inputs[0];
  } else if (name == "concat") {
    for (const auto& c : inputs) out += *c;
  } else if (name == "upper" || name == "lower") {
    out = *inputs[0];
    bool up = name == "upper";
    for (char& c : out) {
      if (up && c >= 'a' && c <= 'z') c = static_cast<char>(c - 32);
      else if (!up && c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
    }
  } else if (name == "grep") {
    const std::string& needle = args[0].asStr();
    for (auto line : splitLines(*inputs[0]))
      if (line.find(needle) != std::string_view::npos) emitLine(out, line);
  } else if (name == "replace") {
    out = replaceAll(*inputs[0], args[0].asStr(), args[1].asStr());
  } else if (name == "sort_lines") {
    auto lines = splitLines(*inputs[0]);
    std::sort(lines.begin(), lines.end());
    for (auto l : lines) emitLine(out, l);
  } else if (name == "reverse_lines") {
    auto lines = splitLines(*inputs[0]);
    for (auto it = lines.rbegin(); it != lines.rend(); ++it) emitLine(out, *it);
  } else if (name == "dedup") {
    std::unordered_set<std::string_view> seen;
    for (auto l : splitLines(*inputs[0]))
      if (seen.insert(l).second) emitLine(out, l);
  } else if (name == "number") {
    std::size_t n = 0;
    for (auto l : splitLines(*inputs[0])) {
      out += std::to_string(++n);
      out += ": ";
      emitLine(out, l);
    }
  } else if (name == "indent") {
    std::string pad(static_cast<std::size_t>(args[0].asInt()), ' ');
    for (auto l : splitLines(*inputs[0])) {
      out += pad;
      emitLine(out, l);
    }
  } else if (name == "wrap") {
    out = args[0].asStr();
    out += *inputs[0];
    out += args[1].asStr();
  } else if (name == "count_lines") {
    std::size_t total = 0;
    auto files = step.fileInputs();
    for (std::size_t i = 0; i < inputs.size(); ++i) {
      std::size_t n = splitLines(*inputs[i]).size();
      total += n;
      out += std::to_string(n) + " " + files[i] + "\n";
    }
    out += std::to_string(total) + " total\n";
  } else if (name == "hash") {
    auto files = step.fileInputs();
    for (std::size_t i = 0; i < inputs.size(); ++i)
      out += toHex16(vfs.hash(files[i])) + " " + files[i] + "\n";
  } else if (name == "preprocess") {
    Preprocessor pp{vfs, {}, {}, {}, {}};
    pp.expand(step.fileInputs()[0], inputs[0]);
    out = std::move(pp.output);
    std::sort(pp.discovered.begin(), pp.discovered.end());
    std::string dep = "kiln-deps 1\n";
    for (const auto& p : pp.discovered) dep += "need " + p + "\n";
    r.depfile = std::move(dep);
    r.discovered = std::move(pp.discovered);
  }
  return r;
}

}  // namespace kiln
