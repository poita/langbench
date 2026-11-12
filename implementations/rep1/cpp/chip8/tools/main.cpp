// chip8 command-line tool: reads a job on stdin, writes the final state to stdout.
#include <cstdio>
#include <exception>
#include <iostream>
#include <iterator>
#include <string>

#include "chip8/chip8.hpp"

int main() {
  try {
    std::ios::sync_with_stdio(false);
    const std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
    const chip8::Machine machine = chip8::run_job(chip8::parse_job(input));
    const std::string report = chip8::format_report(machine);
    std::fwrite(report.data(), 1, report.size(), stdout);
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "chip8: %s\n", e.what());
    return 1;
  }
}
