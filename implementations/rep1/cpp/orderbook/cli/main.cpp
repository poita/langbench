// orderbook: reads commands on stdin, writes events on stdout (see SPEC.md).
#include <cstdio>
#include <iostream>
#include <string>

#include "orderbook/session.hpp"

int main() {
  std::ios::sync_with_stdio(false);

  std::string input;
  char chunk[1 << 16];
  std::size_t got;
  while ((got = std::fread(chunk, 1, sizeof chunk, stdin)) > 0) input.append(chunk, got);

  const orderbook::SessionResult r = orderbook::run_session(input, std::cout);
  std::cout.flush();
  if (!r.ok) {
    std::fprintf(stderr, "orderbook: %s\n", r.error.c_str());
    return 1;
  }
  return 0;
}
