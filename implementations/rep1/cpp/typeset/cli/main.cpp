// Command-line tool: typeset <input directory> <output directory>
//
// Reads <input>/document.cdx and the optional <input>/settings.cfg, resolves
// font and hyphenation data from ./data (or $TYPESET_DATA), and writes
// layout.txt and report.txt (or a single error.txt) into <output>. The exit
// code is 0 even for invalid documents.
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>

#include "typeset/typeset.hpp"

namespace fs = std::filesystem;

namespace {

std::optional<std::string> readFile(const fs::path& p) {
    std::error_code ec;
    if (!fs::is_regular_file(p, ec)) return std::nullopt;
    std::ifstream in(p, std::ios::binary);
    if (!in) return std::nullopt;
    std::stringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

bool writeFile(const fs::path& p, const std::string& text) {
    std::ofstream out(p, std::ios::binary);
    out << text;
    return static_cast<bool>(out);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: " << argv[0] << " <input directory> <output directory>\n";
        return 2;
    }
    const fs::path inDir = argv[1], outDir = argv[2];
    typeset::Input input;
    input.document = readFile(inDir / "document.cdx");
    input.settings = readFile(inDir / "settings.cfg");

    const char* env = std::getenv("TYPESET_DATA");
    const std::string dataDir = env && *env ? env : "data";

    typeset::Result result;
    try {
        result = typeset::run(input, dataDir);
    } catch (const std::exception& e) {
        std::cerr << "typeset: " << e.what() << "\n";
        return 1;
    }

    std::error_code ec;
    fs::create_directories(outDir, ec);
    bool ok;
    if (result.ok) ok = writeFile(outDir / "layout.txt", result.layout) && writeFile(outDir / "report.txt", result.report);
    else ok = writeFile(outDir / "error.txt", result.error);
    if (!ok) {
        std::cerr << "typeset: cannot write output\n";
        return 1;
    }
    return 0;
}
