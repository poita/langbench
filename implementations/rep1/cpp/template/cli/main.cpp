// Command-line tool: reads a document (JSON context, `--`, named templates)
// from stdin, renders the first template and prints the result or
// `error: <kind>`.

#include <cstdio>
#include <exception>
#include <iostream>
#include <iterator>
#include <string>

#include "jinjalite/engine.hpp"

int main() {
  std::ios::sync_with_stdio(false);
  std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
  try {
    std::string out = jinjalite::render_document_or_error_line(input);
    std::fwrite(out.data(), 1, out.size(), stdout);
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "jinjalite: invalid input: %s\n", e.what());
    return 1;
  }
}
