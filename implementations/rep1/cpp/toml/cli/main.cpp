// toml-tool: reads "<mode>\n<document>" on stdin.
//   decode: TOML -> tagged JSON (or the word "error")
//   encode: tagged JSON -> canonical TOML
#include <cstdio>
#include <string>
#include <string_view>

#include "toml/toml.hpp"

namespace {

std::string read_all(std::FILE* f) {
  std::string data;
  char buf[1 << 16];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) data.append(buf, n);
  return data;
}

}  // namespace

int main() {
  const std::string input = read_all(stdin);
  const std::size_t nl = input.find('\n');
  const std::string_view mode = std::string_view(input).substr(0, nl);
  const std::string_view body =
      nl == std::string::npos ? std::string_view() : std::string_view(input).substr(nl + 1);

  std::string out;
  try {
    if (mode == "decode") {
      out = toml::to_tagged_json(toml::parse(body));
      out.push_back('\n');
    } else if (mode == "encode") {
      out = toml::to_toml(toml::from_tagged_json(body));
    } else {
      std::fputs("usage: first input line must be 'decode' or 'encode'\n", stderr);
      return 2;
    }
  } catch (const std::exception& e) {
    if (mode == "decode") {
      out = "error\n";
    } else {
      std::fprintf(stderr, "error: %s\n", e.what());
      return 1;
    }
  }
  std::fwrite(out.data(), 1, out.size(), stdout);
  return 0;
}
