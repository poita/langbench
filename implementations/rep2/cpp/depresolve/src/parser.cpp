#include "depresolve/parser.hpp"

namespace depresolve {

namespace {

bool valid_name(std::string_view name) {
  if (name.empty() || name[0] < 'a' || name[0] > 'z') return false;
  for (char c : name) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
    if (!ok) return false;
  }
  return true;
}

// "name range" -> Dependency
Dependency parse_requirement(std::string_view text, std::size_t line) {
  const std::size_t space = text.find(' ');
  if (space == std::string_view::npos) {
    throw ParseError(line, "requirement '" + std::string(text) + "' lacks a range");
  }
  const auto name = text.substr(0, space);
  if (!valid_name(name)) throw ParseError(line, "invalid package name '" + std::string(name) + "'");
  const auto range_text = text.substr(space + 1);
  const auto range = Range::parse(range_text);
  if (!range) throw ParseError(line, "invalid range '" + std::string(range_text) + "'");
  return Dependency{std::string(name), *range};
}

// Parses what follows the colon: "" or " req, req, ...".
std::vector<Dependency> parse_after_colon(std::string_view text, std::size_t line) {
  if (text.empty()) return {};
  if (text[0] != ' ') throw ParseError(line, "expected a space after ':'");
  return parse_requirements(text.substr(1), line);
}

}  // namespace

std::vector<Dependency> parse_requirements(std::string_view text, std::size_t line) {
  std::vector<Dependency> out;
  if (text.empty()) return out;
  std::size_t pos = 0;
  while (true) {
    const std::size_t sep = text.find(", ", pos);
    const auto item = text.substr(pos, sep == std::string_view::npos ? sep : sep - pos);
    out.push_back(parse_requirement(item, line));
    if (sep == std::string_view::npos) break;
    pos = sep + 2;
  }
  return out;
}

Problem parse_problem(std::string_view text) {
  Problem problem;
  bool have_root = false;
  std::size_t line_no = 0;
  std::size_t pos = 0;
  while (pos < text.size()) {
    const std::size_t eol = text.find('\n', pos);
    const auto line = text.substr(pos, eol == std::string_view::npos ? eol : eol - pos);
    pos = (eol == std::string_view::npos) ? text.size() : eol + 1;
    ++line_no;

    if (have_root) throw ParseError(line_no, "content after the root line");
    if (line.empty()) throw ParseError(line_no, "empty line");

    if (line.substr(0, 5) == "root:") {
      problem.root = parse_after_colon(line.substr(5), line_no);
      have_root = true;
      continue;
    }

    const std::size_t space = line.find(' ');
    const std::size_t colon = line.find(':');
    if (space == std::string_view::npos || colon == std::string_view::npos || colon < space) {
      throw ParseError(line_no, "expected 'name version:'");
    }
    const auto name = line.substr(0, space);
    if (!valid_name(name)) throw ParseError(line_no, "invalid package name '" + std::string(name) + "'");
    const auto version = Version::parse(line.substr(space + 1, colon - space - 1));
    if (!version) throw ParseError(line_no, "invalid version");
    problem.registry.add_version(name, *version, parse_after_colon(line.substr(colon + 1), line_no));
  }
  if (!have_root) throw ParseError(line_no + 1, "missing root line");
  problem.registry.finalize();
  return problem;
}

}  // namespace depresolve
