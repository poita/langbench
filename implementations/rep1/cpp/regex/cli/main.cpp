// regex: reads a batch of patterns and subjects on stdin, prints the first
// match (with capture positions) of each pattern in each subject.
#include <cstdio>
#include <exception>
#include <iostream>

#include "batch.hpp"

int main() {
  std::ios::sync_with_stdio(false);
  try {
    regex::run_batch(std::cin, std::cout);
    std::cout.flush();
  } catch (const std::exception& e) {
    std::cout.flush();
    std::fprintf(stderr, "regex: %s\n", e.what());
    return 1;
  }
  return 0;
}
