// rrule command-line tool: reads "<DTSTART> <RRULE> <N>" lines on stdin and
// prints the first N occurrences of each rule, one line per rule.
#include <cstdio>
#include <iostream>
#include <iterator>
#include <string>
#include <string_view>

#include "rrule/rrule.hpp"

namespace {

// Processes one input line and appends the output line (with LF) to `out`.
void process_line(std::string_view line, std::string& out) {
  try {
    const std::size_t s1 = line.find(' ');
    const std::size_t s2 = s1 == std::string_view::npos
                               ? s1
                               : line.find(' ', s1 + 1);
    if (s2 == std::string_view::npos) throw rrule::ParseError("bad line");
    const rrule::DateTime dtstart = rrule::parse_datetime(line.substr(0, s1));
    const rrule::Rule rule =
        rrule::parse_rule(line.substr(s1 + 1, s2 - s1 - 1));
    const std::string_view n_text = line.substr(s2 + 1);
    std::size_t n = 0;
    if (n_text.empty()) throw rrule::ParseError("bad limit");
    for (char ch : n_text) {
      if (ch < '0' || ch > '9') throw rrule::ParseError("bad limit");
      n = n * 10 + static_cast<std::size_t>(ch - '0');
    }
    bool first = true;
    for (const rrule::DateTime& t : rrule::expand(dtstart, rule, n)) {
      if (!first) out += ' ';
      first = false;
      out += rrule::format_datetime(t);
    }
  } catch (const rrule::ParseError& e) {
    std::fprintf(stderr, "rrule: skipping malformed line: %s\n", e.what());
  }
  out += '\n';
}

}  // namespace

int main() {
  std::ios::sync_with_stdio(false);
  const std::string input((std::istreambuf_iterator<char>(std::cin)),
                          std::istreambuf_iterator<char>());
  std::string out;
  std::size_t pos = 0;
  while (pos < input.size()) {
    std::size_t eol = input.find('\n', pos);
    if (eol == std::string::npos) eol = input.size();
    process_line(std::string_view(input).substr(pos, eol - pos), out);
    pos = eol + 1;
  }
  std::fwrite(out.data(), 1, out.size(), stdout);
  return 0;
}
