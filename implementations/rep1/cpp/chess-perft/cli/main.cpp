// chess-perft: reads perft/divide queries from stdin, one per line, and writes
// one answer per query to stdout. See README.md for the format.
#include <cstdio>
#include <iostream>
#include <string>

#include "chessperft/query.hpp"

int main() {
  std::ios::sync_with_stdio(false);
  int status = 0;
  std::string line;
  while (std::getline(std::cin, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;
    const auto query = chessperft::parseQuery(line);
    if (!query) {
      std::cerr << "chess-perft: malformed query: " << line << '\n';
      status = 1;
      continue;
    }
    std::cout << chessperft::answerQuery(*query);
  }
  std::cout.flush();
  return status;
}
