// ordered-map: reads a command script on stdin, writes one result line per
// command to stdout. See README.md for the protocol.
#include <cstdio>
#include <string>

#include "ordered_map/command_processor.hpp"

int main() {
    std::string input;
    char buf[1 << 16];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, stdin)) > 0) input.append(buf, n);

    std::string output;
    output.reserve(input.size());
    const bool ok = ordered_map::run_script(input, output);

    if (!output.empty() && std::fwrite(output.data(), 1, output.size(), stdout) != output.size())
        return 2;
    std::fflush(stdout);
    if (!ok) {
        std::fputs("ordered-map: malformed input\n", stderr);
        return 1;
    }
    return 0;
}
