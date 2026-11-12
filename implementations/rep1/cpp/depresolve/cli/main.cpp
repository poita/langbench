// depresolve command-line tool: reads a registry + root manifest on stdin and
// prints the first resolution found by the specified search.
#include <cstdio>
#include <iostream>
#include <iterator>
#include <string>

#include "depresolve/output.hpp"
#include "depresolve/parser.hpp"
#include "depresolve/resolver.hpp"

int main() {
  std::ios::sync_with_stdio(false);
  std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
  try {
    depresolve::Problem problem = depresolve::parse_problem(input);
    std::string out = depresolve::format_resolution(depresolve::resolve(problem));
    std::fwrite(out.data(), 1, out.size(), stdout);
  } catch (const depresolve::ParseError& e) {
    std::fprintf(stderr, "depresolve: parse error: %s\n", e.what());
    return 2;
  }
  return 0;
}
