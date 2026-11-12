// jsoncanon: read one JSON document on stdin, print its canonical form (or
// "invalid") on stdout. Exit status is 0 either way.
#include <cstdio>
#include <string>

#include "jsoncanon/jsoncanon.hpp"

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
  std::string output;
  try {
    const std::string input = read_all(stdin);
    auto result = jsoncanon::canonicalize(input);
    output = result ? std::move(*result) : "invalid";
  } catch (...) {
    output = "invalid";
  }
  output.push_back('\n');
  std::fwrite(output.data(), 1, output.size(), stdout);
  return std::fflush(stdout) == 0 ? 0 : 1;
}
