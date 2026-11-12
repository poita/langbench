#include "spreadsheet/script.h"

#include <istream>
#include <ostream>
#include <string>

#include "spreadsheet/parser.h"

namespace spreadsheet {

bool CommandProcessor::execute(std::string_view line, std::ostream& out) {
  if (line == "dump") {
    for (const auto& [ref, value] : sheet_.cells()) {
      out << to_string(ref) << ' ' << value.display() << '\n';
    }
    return true;
  }
  std::size_t sp = line.find(' ');
  if (sp == std::string_view::npos) return false;
  std::string_view word = line.substr(0, sp);
  std::string_view rest = line.substr(sp + 1);
  std::size_t sp2 = rest.find(' ');
  std::string_view name = rest.substr(0, sp2);
  auto ref = parse_cell_ref(name);
  if (!ref) return false;

  if (word == "set") {
    if (sp2 == std::string_view::npos) return false;
    try {
      sheet_.set_content(*ref, rest.substr(sp2 + 1));
    } catch (const ParseError&) {
      return false;
    }
    return true;
  }
  if (sp2 != std::string_view::npos) return false;
  if (word == "get") {
    out << sheet_.display(*ref) << '\n';
    return true;
  }
  if (word == "clear") {
    sheet_.clear(*ref);
    return true;
  }
  return false;
}

std::size_t CommandProcessor::run(std::istream& in, std::ostream& out, std::ostream& err) {
  std::size_t bad = 0;
  std::string line;
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;
    if (!execute(line, out)) {
      ++bad;
      err << "ssheet: ignoring malformed command: " << line << '\n';
    }
  }
  return bad;
}

}  // namespace spreadsheet
