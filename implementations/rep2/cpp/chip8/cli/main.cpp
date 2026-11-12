// chip8: reads "<rom-hex>\n<cycles>\n[<key-schedule>]" on stdin, runs the
// machine, and prints the display plus CPU state on stdout.
#include <cstdio>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>

#include "chip8/chip8.hpp"

int main() {
    std::ios::sync_with_stdio(false);
    const std::string input{std::istreambuf_iterator<char>(std::cin), std::istreambuf_iterator<char>()};
    try {
        const chip8::Program program = chip8::parse_program(input);
        const chip8::Machine machine = chip8::run_program(program);
        const std::string out = chip8::format_state(machine);
        std::fwrite(out.data(), 1, out.size(), stdout);
    } catch (const std::invalid_argument& e) {
        std::fprintf(stderr, "chip8: invalid input: %s\n", e.what());
        return 1;
    }
    return 0;
}
