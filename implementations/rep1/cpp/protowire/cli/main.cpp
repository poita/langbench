// protowire CLI: reads a schema and requests from stdin, writes one result
// line per request to stdout. See README.md for the format.
#include <cstdio>
#include <iostream>
#include <iterator>
#include <string>

#include "protowire/batch.hpp"

int main() {
  std::ios::sync_with_stdio(false);
  std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
  const std::string output = protowire::processInput(input);
  std::fwrite(output.data(), 1, output.size(), stdout);
  return 0;
}
