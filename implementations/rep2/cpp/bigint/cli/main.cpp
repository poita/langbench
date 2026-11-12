// bigint_cli: reads queries ("<a> <op> <b>", one per line) from stdin and
// writes one result line per query to stdout. See README.md.
#include <cstdio>
#include <exception>
#include <string>

#include "bigint/query.hpp"

int main() {
    std::string input;
    char buf[1 << 16];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, stdin)) > 0) input.append(buf, n);

    try {
        const std::string out = bigint::evaluate_queries(input);
        if (std::fwrite(out.data(), 1, out.size(), stdout) != out.size()) return 1;
        return std::fflush(stdout) == 0 ? 0 : 1;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "bigint_cli: %s\n", e.what());
        return 1;
    }
}
