// Command-line tool: reads a Datalog program on stdin, prints query answers
// (or `error`) on stdout.
#include <cstdio>
#include <iostream>
#include <iterator>
#include <string>

#include "datalog/datalog.h"

int main() {
  std::ios::sync_with_stdio(false);
  std::string source((std::istreambuf_iterator<char>(std::cin)),
                     std::istreambuf_iterator<char>());
  try {
    std::string out = datalog::run_program(source);
    std::fwrite(out.data(), 1, out.size(), stdout);
  } catch (const datalog::ParseError& e) {
    std::fprintf(stderr, "parse error: %s\n", e.what());
    std::fputs("error\n", stdout);
  }
  return 0;
}
