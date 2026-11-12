#include "batch.hpp"

#include <charconv>
#include <istream>
#include <ostream>
#include <string>

#include "regex/regex.hpp"

namespace regex {
namespace {

bool read_line(std::istream& in, std::string& line) {
  return static_cast<bool>(std::getline(in, line));
}

long read_count(std::istream& in, std::string& line, const char* what) {
  if (!read_line(in, line)) throw BatchError(std::string("unexpected end of input reading ") + what);
  long v = 0;
  auto [p, ec] = std::from_chars(line.data(), line.data() + line.size(), v);
  if (ec != std::errc() || p != line.data() + line.size() || v < 0)
    throw BatchError(std::string("invalid ") + what + ": '" + line + "'");
  return v;
}

void append_number(std::string& out, std::size_t v) {
  char buf[24];
  auto r = std::to_chars(buf, buf + sizeof buf, v);
  out.append(buf, r.ptr);
}

void format_result(std::string& out, const Match& m) {
  out += "match ";
  append_number(out, m.span.begin);
  out += ' ';
  append_number(out, m.span.end);
  for (const auto& g : m.groups) {
    out += '|';
    if (g) {
      append_number(out, g->begin);
      out += ',';
      append_number(out, g->end);
    } else {
      out += '-';
    }
  }
  out += '\n';
}

}  // namespace

void run_batch(std::istream& in, std::ostream& out) {
  std::string line, pattern, buf;
  const long patterns = read_count(in, line, "pattern count");
  Match match;
  for (long p = 0; p < patterns; ++p) {
    if (!read_line(in, pattern)) throw BatchError("unexpected end of input reading a pattern");
    const long subjects = read_count(in, line, "subject count");
    Regex re(pattern);
    Matcher matcher(re.program());
    for (long s = 0; s < subjects; ++s) {
      if (!read_line(in, line)) throw BatchError("unexpected end of input reading a subject");
      if (matcher.search(line, match)) format_result(buf, match);
      else buf += "no\n";
      if (buf.size() >= (1u << 16)) {
        out.write(buf.data(), static_cast<std::streamsize>(buf.size()));
        buf.clear();
      }
    }
  }
  out.write(buf.data(), static_cast<std::streamsize>(buf.size()));
}

}  // namespace regex
