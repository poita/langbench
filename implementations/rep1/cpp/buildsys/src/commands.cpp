#include "kiln/commands.hpp"

#include <algorithm>
#include <set>
#include <unordered_set>

#include "kiln/builtins.hpp"
#include "kiln/error.hpp"
#include "kiln/hash.hpp"
#include "kiln/path.hpp"

namespace kiln {

namespace {

const std::vector<CommandSpec>& specs() {
  static const std::vector<CommandSpec> t = {
      {"write", {ArgType::Str}, 0, 0, false, 1},
      {"copy", {}, 1, 1, false, 1},
      {"concat", {}, 1, -1, false, 2},
      {"upper", {}, 1, 1, false, 2},
      {"lower", {}, 1, 1, false, 2},
      {"grep", {ArgType::Str}, 1, 1, false, 3},
      {"replace", {ArgType::Str, ArgType::Str}, 1, 1, false, 3},
      {"sort_lines", {}, 1, 1, false, 4},
      {"reverse_lines", {}, 1, 1, false, 2},
      {"dedup", {}, 1, 1, false, 3},
      {"number", {}, 1, 1, false, 2},
      {"indent", {ArgType::Int}, 1, 1, false, 2},
      {"wrap", {ArgType::Str, ArgType::Str}, 1, 1, false, 1},
      {"count_lines", {}, 1, -1, false, 2},
      {"hash", {}, 1, -1, false, 3},
      {"preprocess", {}, 1, 1, true, 6},
  };
  return t;
}

void escape_into(std::string& out, const std::string& s) {
  static const char hex[] = "0123456789abcdef";
  out += '"';
  for (char ch : s) {
    auto c = static_cast<unsigned char>(ch);
    if (c == '\\') out += "\\\\";
    else if (c == '"') out += "\\\"";
    else if (c == '\n') out += "\\n";
    else if (c == '\t') out += "\\t";
    else if (c == '\r') out += "\\r";
    else if (c < 0x20 || c == 0x7f) {
      out += "\\x";
      out += hex[c >> 4];
      out += hex[c & 15];
    } else {
      out += ch;
    }
  }
  out += '"';
}

void append_lines(std::string& out, const std::vector<std::string_view>& lines) {
  for (auto l : lines) {
    out.append(l);
    out += '\n';
  }
}

// --- preprocess -----------------------------------------------------------

struct Expander {
  const Vfs& fs;
  std::vector<std::string> stack;
  std::set<std::string> discovered;
  std::string out;

  void expand(const std::string& path, const Vfs::Content& content) {
    stack.push_back(path);
    for (std::string_view line : split_lines(*content)) {
      static constexpr std::string_view kNeed = "@need ";
      if (line.size() > kNeed.size() && line.substr(0, kNeed.size()) == kNeed) {
        std::string q(line.substr(kNeed.size()));
        if (!is_workspace_path(q)) throw Error(ErrorKind::NeedPath, q);
        Vfs::Content c = fs.read(q);
        if (!c) throw Error(ErrorKind::NeedMissing, q + " needed by " + path);
        if (std::find(stack.begin(), stack.end(), q) != stack.end()) throw Error(ErrorKind::NeedCycle, q);
        discovered.insert(q);
        expand(q, c);
      } else {
        out.append(line);
        out += '\n';
      }
    }
    stack.pop_back();
  }
};

}  // namespace

const CommandSpec* find_command(std::string_view name) {
  for (const auto& s : specs()) {
    if (s.name == name) return &s;
  }
  return nullptr;
}

std::string canonical_command(const CommandSpec& spec, const std::vector<Value>& args) {
  std::string out(spec.name);
  out += '(';
  for (std::size_t i = 0; i < args.size(); ++i) {
    if (i) out += ", ";
    if (args[i].is(Type::Int)) out += std::to_string(args[i].as_int());
    else escape_into(out, args[i].as_str());
  }
  out += ')';
  return out;
}

void check_command_args(const CommandSpec& spec, const std::vector<Value>& args) {
  if (spec.name == "replace" && args[0].as_str().empty()) throw_arg_error("cmd", "replace", "empty pattern");
  if (spec.name == "indent" && args[0].as_int() < 0) throw_arg_error("cmd", "indent", "negative");
}

std::vector<std::string_view> split_lines(std::string_view content) {
  std::vector<std::string_view> lines;
  std::size_t pos = 0;
  while (pos < content.size()) {
    std::size_t nl = content.find('\n', pos);
    if (nl == std::string_view::npos) {
      lines.push_back(content.substr(pos));
      break;
    }
    lines.push_back(content.substr(pos, nl - pos));
    pos = nl + 1;
  }
  return lines;
}

CommandResult run_command(const CommandSpec& spec, const std::vector<Value>& args,
                          const std::vector<CommandInput>& inputs, const Vfs& fs) {
  CommandResult r;
  const std::string_view name = spec.name;
  auto in0 = [&]() -> const std::string& { return *inputs[0].content; };

  if (name == "write") {
    r.output = args[0].as_str();
  } else if (name == "copy") {
    r.output = in0();
  } else if (name == "concat") {
    for (const auto& in : inputs) r.output += *in.content;
  } else if (name == "upper") {
    r.output = in0();
    for (char& c : r.output) if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 32);
  } else if (name == "lower") {
    r.output = in0();
    for (char& c : r.output) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
  } else if (name == "grep") {
    std::vector<std::string_view> keep;
    for (auto l : split_lines(in0())) {
      if (l.find(args[0].as_str()) != std::string_view::npos) keep.push_back(l);
    }
    append_lines(r.output, keep);
  } else if (name == "replace") {
    r.output = replace_all(in0(), args[0].as_str(), args[1].as_str());
  } else if (name == "sort_lines") {
    auto lines = split_lines(in0());
    std::stable_sort(lines.begin(), lines.end());
    append_lines(r.output, lines);
  } else if (name == "reverse_lines") {
    auto lines = split_lines(in0());
    std::reverse(lines.begin(), lines.end());
    append_lines(r.output, lines);
  } else if (name == "dedup") {
    std::unordered_set<std::string_view> seen;
    std::vector<std::string_view> keep;
    for (auto l : split_lines(in0())) {
      if (seen.insert(l).second) keep.push_back(l);
    }
    append_lines(r.output, keep);
  } else if (name == "number") {
    std::size_t n = 0;
    for (auto l : split_lines(in0())) {
      r.output += std::to_string(++n);
      r.output += ": ";
      r.output.append(l);
      r.output += '\n';
    }
  } else if (name == "indent") {
    std::string pad(static_cast<std::size_t>(args[0].as_int()), ' ');
    for (auto l : split_lines(in0())) {
      r.output += pad;
      r.output.append(l);
      r.output += '\n';
    }
  } else if (name == "wrap") {
    r.output = args[0].as_str() + in0() + args[1].as_str();
  } else if (name == "count_lines") {
    std::size_t total = 0;
    for (const auto& in : inputs) {
      std::size_t n = split_lines(*in.content).size();
      total += n;
      r.output += std::to_string(n) + " " + in.path + "\n";
    }
    r.output += std::to_string(total) + " total\n";
  } else if (name == "hash") {
    for (const auto& in : inputs) r.output += hash_to_hex(fnv1a64(*in.content)) + " " + in.path + "\n";
  } else if (name == "preprocess") {
    Expander ex{fs, {}, {}, {}};
    ex.expand(inputs[0].path, inputs[0].content);
    r.output = std::move(ex.out);
    r.depfile = "kiln-deps 1\n";
    for (const auto& d : ex.discovered) {
      r.depfile += "need " + d + "\n";
      r.discovered.push_back(d);
    }
  }
  return r;
}

}  // namespace kiln
