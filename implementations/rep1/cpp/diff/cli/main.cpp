// mdiff: reads one request on stdin, writes the response on stdout.
// See README.md / SPEC.md for the format.
#include <cstdio>
#include <exception>
#include <string>

#include "mdiff/protocol.hpp"

int main() {
  std::string input;
  char buf[1 << 16];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, stdin)) > 0) input.append(buf, n);

  try {
    const std::string out = mdiff::process_request(input);
    if (std::fwrite(out.data(), 1, out.size(), stdout) != out.size()) return 1;
    return std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "mdiff: %s\n", e.what());
    return 1;
  }
}
