// textbuffer command-line tool: reads a document and commands from stdin,
// writes the output of every `print` command to stdout.

#include <cstdio>
#include <iostream>
#include <string>

#include "textbuffer/script.hpp"

namespace {

std::string readAll(std::FILE* f) {
    std::string data;
    char buf[1 << 16];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) data.append(buf, n);
    return data;
}

}  // namespace

int main() {
    std::ios::sync_with_stdio(false);
    const std::string input = readAll(stdin);
    textbuffer::runScript(input, std::cout, &std::cerr);
    std::cout.flush();
    return std::cout ? 0 : 1;
}
