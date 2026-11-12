// scheme: read a Scheme program on stdin, evaluate it, write results to stdout.
#include <cstdio>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>

#include "scheme/interpreter.hpp"
#include "scheme/stack.hpp"

int main() {
  std::ios::sync_with_stdio(false);
  std::string source((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());

  std::ostringstream out;  // buffered; flushed once at the end
  scheme::run_with_stack_size(scheme::kDefaultStackBytes, [&] {
    scheme::Interpreter interp;
    interp.run(source, out);
  });
  std::string text = out.str();
  std::fwrite(text.data(), 1, text.size(), stdout);
  std::fflush(stdout);
  return 0;
}
