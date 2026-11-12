// spiremark: reads a match file on stdin and writes the match log to stdout.
#include <iostream>
#include <iterator>
#include <string>

#include "spiremark/session.hpp"

int main() {
    std::ios::sync_with_stdio(false);
    std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
    spiremark::run_match(input, std::cout);
    std::cout.flush();
    return 0;
}
