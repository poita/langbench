#include "rx/batch.hpp"

#include <cstring>
#include <ostream>

#include "rx/regex.hpp"

namespace rx {
namespace {

class LineReader {
 public:
  explicit LineReader(std::string_view in) : in_(in) {}

  bool done() const { return pos_ >= in_.size(); }

  // Next line without its '\n'. A missing final '\n' is tolerated.
  std::string_view next() {
    if (done()) throw BatchError("unexpected end of input");
    const char* base = in_.data() + pos_;
    std::size_t rest = in_.size() - pos_;
    const void* nl = std::memchr(base, '\n', rest);
    std::size_t len = nl ? static_cast<std::size_t>(static_cast<const char*>(nl) - base) : rest;
    pos_ += len + (nl ? 1 : 0);
    return std::string_view(base, len);
  }

  std::size_t next_count(const char* what) {
    std::string_view line = next();
    if (line.empty() || line.size() > 18) throw BatchError(std::string("bad ") + what);
    std::size_t v = 0;
    for (char c : line) {
      if (c < '0' || c > '9') throw BatchError(std::string("bad ") + what);
      v = v * 10 + static_cast<std::size_t>(c - '0');
    }
    return v;
  }

 private:
  std::string_view in_;
  std::size_t pos_ = 0;
};

void append_number(std::string& out, std::size_t v) {
  char buf[24];
  char* p = buf + sizeof buf;
  do {
    *--p = static_cast<char>('0' + v % 10);
    v /= 10;
  } while (v);
  out.append(p, static_cast<std::size_t>(buf + sizeof buf - p));
}

}  // namespace

void format_result(bool matched, const Match& m, std::string& out) {
  if (!matched) {
    out += "no\n";
    return;
  }
  out += "match ";
  append_number(out, m.begin);
  out += ' ';
  append_number(out, m.end);
  for (const Span& g : m.groups) {
    out += '|';
    if (g.matched()) {
      append_number(out, g.begin);
      out += ',';
      append_number(out, g.end);
    } else {
      out += '-';
    }
  }
  out += '\n';
}

void run_batch(std::string_view input, std::ostream& out) {
  constexpr std::size_t kFlushAt = 1 << 16;
  LineReader reader(input);
  std::string buf;
  buf.reserve(kFlushAt + 4096);
  Match match;

  const std::size_t n = reader.next_count("pattern count");
  for (std::size_t p = 0; p < n; ++p) {
    std::string_view pattern = reader.next();
    const std::size_t m = reader.next_count("subject count");
    try {
      Regex re{pattern};
      Matcher matcher(re.program());
      for (std::size_t i = 0; i < m; ++i) {
        std::string_view subject = reader.next();
        format_result(matcher.search(subject, match), match, buf);
        if (buf.size() >= kFlushAt) {
          out.write(buf.data(), static_cast<std::streamsize>(buf.size()));
          buf.clear();
        }
      }
    } catch (const ParseError& e) {
      throw BatchError("pattern " + std::to_string(p + 1) + ": " + e.what());
    }
  }
  out.write(buf.data(), static_cast<std::streamsize>(buf.size()));
}

}  // namespace rx
