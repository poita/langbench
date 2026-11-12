#include "mdiff/protocol.hpp"

#include "mdiff/diff.hpp"
#include "mdiff/patch.hpp"

namespace mdiff {
namespace {

// Sequential reader over '\n'-terminated lines of a buffer.
class Reader {
public:
  explicit Reader(std::string_view text) : text_(text) {}

  // Next line without its '\n'; a missing final '\n' is tolerated.
  Line next() {
    if (pos_ >= text_.size()) throw ProtocolError("unexpected end of input");
    std::size_t nl = text_.find('\n', pos_);
    Line l;
    if (nl == std::string_view::npos) {
      l = text_.substr(pos_);
      pos_ = text_.size();
    } else {
      l = text_.substr(pos_, nl - pos_);
      pos_ = nl + 1;
    }
    return l;
  }

  // A count line: digits, optionally followed by spaces/tabs/'\r'.
  std::size_t next_count() {
    Line l = next();
    while (!l.empty() && (l.back() == ' ' || l.back() == '\t' || l.back() == '\r')) l.remove_suffix(1);
    if (l.empty() || l.size() > 9) throw ProtocolError("bad count line");
    std::size_t v = 0;
    for (char c : l) {
      if (c < '0' || c > '9') throw ProtocolError("bad count line");
      v = v * 10 + static_cast<std::size_t>(c - '0');
    }
    return v;
  }

  Lines next_lines(std::size_t count) {
    Lines out;
    out.reserve(count);
    for (std::size_t i = 0; i < count; ++i) out.push_back(next());
    return out;
  }

private:
  std::string_view text_;
  std::size_t pos_ = 0;
};

void append_count(std::string& out, std::size_t n) { out += std::to_string(n); out.push_back('\n'); }

}  // namespace

std::string process_request(std::string_view input) {
  Reader in(input);
  Line mode = in.next();
  while (!mode.empty() && (mode.back() == ' ' || mode.back() == '\t' || mode.back() == '\r')) mode.remove_suffix(1);

  const Lines a = in.next_lines(in.next_count());
  std::string out;
  if (mode == "diff") {
    const Lines b = in.next_lines(in.next_count());
    const EditScript script = diff_lines(a, b);
    out.reserve(input.size() + script.size() * 2 + 16);
    append_count(out, script.size());
    out += render_script(script, a, b);
  } else if (mode == "patch") {
    const Lines script = in.next_lines(in.next_count());
    const Lines b = apply_script(a, script);
    out.reserve(input.size() + 16);
    append_count(out, b.size());
    for (Line l : b) {
      out.append(l);
      out.push_back('\n');
    }
  } else {
    throw ProtocolError("unknown mode");
  }
  return out;
}

}  // namespace mdiff
