// Command-line front end: reads "<ecl> <mask> <text>" queries from stdin and
// prints the resulting symbols (see SPEC.md).

#include <cstdio>
#include <iostream>
#include <iterator>
#include <string>
#include <string_view>

#include "qrcode/qrcode.hpp"

namespace {

bool parseEcl(char c, qrcode::Ecl& ecl) {
    switch (c) {
        case 'L': ecl = qrcode::Ecl::L; return true;
        case 'M': ecl = qrcode::Ecl::M; return true;
        case 'Q': ecl = qrcode::Ecl::Q; return true;
        case 'H': ecl = qrcode::Ecl::H; return true;
    }
    return false;
}

bool parseQuery(std::string_view line, qrcode::Ecl& ecl, int& mask, std::string_view& text) {
    // "<ecl> <mask> <text>": ecl one char, mask a digit or "auto".
    if (line.size() < 4 || line[1] != ' ' || !parseEcl(line[0], ecl)) return false;
    std::size_t second = line.find(' ', 2);
    if (second == std::string_view::npos || second + 1 >= line.size()) return false;
    std::string_view m = line.substr(2, second - 2);
    if (m == "auto") {
        mask = qrcode::kAutoMask;
    } else if (m.size() == 1 && m[0] >= '0' && m[0] <= '7') {
        mask = m[0] - '0';
    } else {
        return false;
    }
    text = line.substr(second + 1);
    return true;
}

}  // namespace

int main() {
    std::ios::sync_with_stdio(false);
    std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());

    std::string out;
    std::size_t pos = 0;
    int lineNo = 0;
    while (pos < input.size()) {
        std::size_t end = input.find('\n', pos);
        if (end == std::string::npos) end = input.size();
        std::string_view line(input.data() + pos, end - pos);
        pos = end + 1;
        ++lineNo;
        if (!line.empty() && line.back() == '\r') line.remove_suffix(1);

        qrcode::Ecl ecl;
        int mask;
        std::string_view text;
        if (!parseQuery(line, ecl, mask, text)) {
            std::fprintf(stderr, "qrcode-cli: line %d: malformed query\n", lineNo);
            return 1;
        }
        try {
            qrcode::Symbol s = qrcode::encode(text, ecl, mask);
            out += "version " + std::to_string(s.version()) + " mask " + std::to_string(s.mask()) + "\n";
            out += s.toString();
            out += "\n";
        } catch (const std::exception& e) {
            std::fprintf(stderr, "qrcode-cli: line %d: %s\n", lineNo, e.what());
            return 1;
        }
        if (out.size() > (1u << 22)) {
            std::fwrite(out.data(), 1, out.size(), stdout);
            out.clear();
        }
    }
    std::fwrite(out.data(), 1, out.size(), stdout);
    return std::fflush(stdout) == 0 ? 0 : 1;
}
