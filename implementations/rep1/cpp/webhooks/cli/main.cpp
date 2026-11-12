// Command-line front end: reads commands on stdin, writes results to stdout.
// See README.md and SPEC.md for the command language. Always exits 0.
#include <cstdio>
#include <string>

#include "webhooks/protocol.hpp"

int main() {
  std::string input;
  char buffer[1 << 16];
  std::size_t n;
  while ((n = std::fread(buffer, 1, sizeof buffer, stdin)) > 0) input.append(buffer, n);

  std::string output;
  try {
    output = webhooks::run_commands(input);
  } catch (...) {
    output = "error\n";  // defensive: the library is not expected to throw
  }
  std::fwrite(output.data(), 1, output.size(), stdout);
  return 0;
}
