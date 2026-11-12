// linalg_cli <input directory> <output directory>
#include <exception>
#include <iostream>

#include "driver.hpp"

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: " << argv[0] << " <input directory> <output directory>\n";
        return 2;
    }
    try {
        linalg::cli::run_script(argv[1], argv[2]);
    } catch (const std::exception& e) {
        std::cerr << "error: " << e.what() << "\n";
    }
    return 0;  // the contract is: always exit 0
}
