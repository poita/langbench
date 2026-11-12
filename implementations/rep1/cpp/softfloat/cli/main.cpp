// softfloat_cli: read operations on stdin, write binary32 result patterns on stdout.
#include <cstdio>
#include <string>

#include "softfloat/line.h"

int main() {
  std::string input;
  char buf[1 << 16];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, stdin)) > 0) input.append(buf, n);

  std::size_t bad = 0;
  const auto out = softfloat::evaluate_all(input, &bad);
  if (!out) {
    std::fprintf(stderr, "softfloat_cli: malformed input on line %zu\n", bad);
    return 1;
  }
  std::fwrite(out->data(), 1, out->size(), stdout);
  return std::fflush(stdout) == 0 ? 0 : 1;
}
