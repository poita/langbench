// datalog: read a program on stdin, print the answers to its queries.
#include <cstdio>
#include <iostream>
#include <iterator>
#include <string>

#include "datalog/datalog.h"

int main() {
  std::ios::sync_with_stdio(false);
  std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
  std::string output;
  try {
    output = datalog::run_program(input);
  } catch (const datalog::Error& e) {
    std::fprintf(stderr, "datalog: %s\n", e.what());
    output = "error\n";
  }
  std::fwrite(output.data(), 1, output.size(), stdout);
  return 0;
}
