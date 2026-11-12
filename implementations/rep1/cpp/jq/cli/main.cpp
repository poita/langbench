// jq-subset command-line tool.
//
// stdin:  line 1 = filter, rest = one JSON document.
// stdout: every result as compact JSON, one per line; if evaluation fails,
//         the results so far followed by a line `error`. Exit status is 0.
#include <cstdio>
#include <string>

#include "jq/jq.hpp"

namespace {

std::string read_all(std::FILE* f) {
  std::string data;
  char buf[1 << 16];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) data.append(buf, n);
  return data;
}

void flush(std::string& out) {
  std::fwrite(out.data(), 1, out.size(), stdout);
  out.clear();
}

}  // namespace

int main() {
  const std::string input = read_all(stdin);
  const std::size_t nl = input.find('\n');
  const std::string filter_text = input.substr(0, nl);
  const std::string_view document =
      nl == std::string::npos ? std::string_view() : std::string_view(input).substr(nl + 1);

  std::string out;
  try {
    jq::Filter filter = jq::Filter::compile(filter_text);
    jq::Value doc = jq::parse_json(document);
    filter.run(doc, [&](const jq::Value& v) {
      jq::write_json(v, out);
      out.push_back('\n');
      if (out.size() >= (1u << 16)) flush(out);
    });
  } catch (const jq::Error&) {
    out += "error\n";
  } catch (const std::exception&) {
    out += "error\n";
  }
  flush(out);
  return 0;
}
