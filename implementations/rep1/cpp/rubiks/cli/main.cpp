// rubiks: read scrambles (one per line) from stdin, print a solution per line.
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

#include "rubiks/rubiks.hpp"

int main() {
  std::string input;
  char buf[1 << 16];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, stdin)) > 0) input.append(buf, n);

  rubiks::Solver solver;
  std::string output;
  std::vector<rubiks::Move> scramble;

  std::size_t pos = 0;
  std::size_t lineNo = 0;
  while (pos < input.size()) {
    std::size_t end = input.find('\n', pos);
    if (end == std::string::npos) end = input.size();
    ++lineNo;
    scramble.clear();
    if (!rubiks::parseMovesInto(std::string_view(input).substr(pos, end - pos), scramble)) {
      std::fprintf(stderr, "rubiks: invalid move token on line %zu\n", lineNo);
      return 1;
    }
    rubiks::Solution sol = solver.solve(scramble);
    output += rubiks::toString(sol.moves);
    output += '\n';
    pos = end + 1;
  }
  std::fwrite(output.data(), 1, output.size(), stdout);
  return 0;
}
