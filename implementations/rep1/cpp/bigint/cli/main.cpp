// Command-line front end: reads queries on stdin, writes results to stdout.
#include <exception>
#include <iostream>

#include "bigint/query.hpp"

int main() {
  std::ios::sync_with_stdio(false);
  try {
    bigint::run_queries(std::cin, std::cout);
    std::cout.flush();
  } catch (const std::exception& e) {
    std::cerr << "bigint: " << e.what() << '\n';
    return 1;
  }
  return 0;
}
