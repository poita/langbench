// depresolve: reads a registry + root manifest on stdin, prints the resolution.
#include <cstdio>
#include <exception>
#include <string>

#include "depresolve/depresolve.hpp"

namespace {

std::string read_all(std::FILE* in) {
  std::string data;
  char buffer[1 << 16];
  std::size_t n;
  while ((n = std::fread(buffer, 1, sizeof buffer, in)) > 0) data.append(buffer, n);
  return data;
}

}  // namespace

int main() {
  try {
    const std::string output = depresolve::resolve_text(read_all(stdin));
    std::fwrite(output.data(), 1, output.size(), stdout);
    return std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "depresolve: %s\n", e.what());
    return 2;
  }
}
