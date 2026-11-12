// Command-line front end: reads one filter line and one JSON document from
// stdin, prints every result as compact JSON, one per line. If evaluation
// fails, prints `error` after the results produced so far. Always exits 0.
#include <cstdio>
#include <iostream>
#include <iterator>
#include <string>

#include "jq/jq.hpp"

namespace {

void flush(std::string& buf) {
  std::fwrite(buf.data(), 1, buf.size(), stdout);
  buf.clear();
}

}  // namespace

int main() {
  std::ios::sync_with_stdio(false);
  std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());

  std::size_t nl = input.find('\n');
  std::string program = input.substr(0, nl);
  std::string document = nl == std::string::npos ? std::string() : input.substr(nl + 1);
  if (!program.empty() && program.back() == '\r') program.pop_back();

  std::string buf;
  try {
    jq::Filter filter = jq::Filter::compile(program);
    jq::Value doc = jq::parse_json(document);
    jq::RunStatus st = filter.run(doc, [&](const jq::Value& v) {
      jq::write_json(v, buf);
      buf += '\n';
      if (buf.size() > (1u << 16)) flush(buf);
      return true;
    });
    if (!st.ok) {
      buf += "error\n";
      std::fprintf(stderr, "jq: error: %s\n", st.error.c_str());
    }
  } catch (const std::exception& e) {
    std::fprintf(stderr, "jq: %s\n", e.what());
    buf += "error\n";
  }
  flush(buf);
  return 0;
}
