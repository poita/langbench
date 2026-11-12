#include "depresolve/parser.hpp"

#include <utility>

namespace depresolve {

namespace {

bool is_name_start(char c) { return c >= 'a' && c <= 'z'; }
bool is_name_char(char c) { return is_name_start(c) || (c >= '0' && c <= '9') || c == '-'; }

// Parses the text after the ':' of a line: "" or " req(, req)*".
std::vector<Requirement> parse_requirements(Registry& registry, std::string_view text,
                                            std::size_t line_no) {
  std::vector<Requirement> out;
  if (text.empty()) return out;
  if (text[0] != ' ') throw ParseError(line_no, "expected space after ':'");
  text.remove_prefix(1);
  while (true) {
    std::size_t comma = text.find(',');
    std::string_view req = text.substr(0, comma);
    std::size_t space = req.find(' ');
    if (space == std::string_view::npos || space == 0) throw ParseError(line_no, "malformed requirement");
    std::string_view name = req.substr(0, space);
    if (!is_name_start(name[0])) throw ParseError(line_no, "bad package name");
    for (char c : name) {
      if (!is_name_char(c)) throw ParseError(line_no, "bad package name");
    }
    auto range = Range::parse(req.substr(space + 1));
    if (!range) throw ParseError(line_no, "bad range");
    out.push_back(Requirement{registry.intern(name), *range});
    if (comma == std::string_view::npos) break;
    if (comma + 1 >= text.size() || text[comma + 1] != ' ') throw ParseError(line_no, "expected ', ' between requirements");
    text.remove_prefix(comma + 2);
  }
  return out;
}

}  // namespace

Problem parse_problem(std::string_view text) {
  Problem problem;
  bool have_root = false;
  std::size_t line_no = 0;
  while (!text.empty()) {
    ++line_no;
    if (have_root) throw ParseError(line_no, "content after root line");
    std::size_t nl = text.find('\n');
    std::string_view line = text.substr(0, nl);
    text.remove_prefix(nl == std::string_view::npos ? text.size() : nl + 1);

    if (line.substr(0, 5) == "root:") {
      problem.root = parse_requirements(problem.registry, line.substr(5), line_no);
      have_root = true;
      continue;
    }
    std::size_t colon = line.find(':');
    if (colon == std::string_view::npos) throw ParseError(line_no, "missing ':'");
    std::string_view head = line.substr(0, colon);
    std::size_t space = head.find(' ');
    if (space == std::string_view::npos || space == 0) throw ParseError(line_no, "expected 'name version'");
    std::string_view name = head.substr(0, space);
    if (!is_name_start(name[0])) throw ParseError(line_no, "bad package name");
    for (char c : name) {
      if (!is_name_char(c)) throw ParseError(line_no, "bad package name");
    }
    auto version = Version::parse(head.substr(space + 1));
    if (!version) throw ParseError(line_no, "bad version");
    PackageId id = problem.registry.intern(name);
    auto reqs = parse_requirements(problem.registry, line.substr(colon + 1), line_no);
    problem.registry.add_version(id, *version, std::move(reqs));
  }
  if (!have_root) throw ParseError(line_no + 1, "missing root line");
  return problem;
}

}  // namespace depresolve
