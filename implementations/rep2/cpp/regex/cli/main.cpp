// regex_cli: reads a batch of patterns and subjects on stdin and prints, for
// each subject, the first match and its capture positions (see README.md).
#include <cstdio>
#include <exception>
#include <iostream>
#include <string>

#include "rx/batch.hpp"

namespace {

std::string read_all(std::FILE* f) {
  std::string data;
  std::size_t used = 0;
  data.resize(1 << 20);
  for (;;) {
    std::size_t got = std::fread(&data[used], 1, data.size() - used, f);
    used += got;
    if (used < data.size()) break;  // EOF (or error)
    data.resize(data.size() * 2);
  }
  data.resize(used);
  return data;
}

}  // namespace

int main() {
  std::ios::sync_with_stdio(false);
  try {
    const std::string input = read_all(stdin);
    rx::run_batch(input, std::cout);
    std::cout.flush();
  } catch (const std::exception& e) {
    std::cout.flush();
    std::cerr << "regex_cli: " << e.what() << '\n';
    return 1;
  }
  return 0;
}
