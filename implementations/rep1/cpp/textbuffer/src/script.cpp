#include "textbuffer/script.hpp"

#include <charconv>
#include <ostream>
#include <string>
#include <vector>

#include "textbuffer/command.hpp"
#include "textbuffer/editor.hpp"

namespace textbuffer {

namespace {

// Pops the next line (without its '\n') off the front of `input`.
std::string_view nextLine(std::string_view& input) {
    const auto nl = input.find('\n');
    const std::string_view line = input.substr(0, nl);
    input.remove_prefix(nl == std::string_view::npos ? input.size() : nl + 1);
    return line;
}

}  // namespace

std::size_t runScript(std::string_view input, std::ostream& out, std::ostream* err) {
    std::size_t count = 0;
    {
        const std::string_view header = nextLine(input);
        std::size_t n = 0;
        std::from_chars(header.data(), header.data() + header.size(), n);
        count = n;
    }

    std::vector<std::string> lines;
    lines.reserve(count);
    for (std::size_t i = 0; i < count && !input.empty(); ++i) {
        lines.emplace_back(nextLine(input));
    }
    Editor editor{Document(std::move(lines))};

    std::size_t skipped = 0;
    std::size_t lineNo = 1 + count;
    while (!input.empty()) {
        const std::string_view line = nextLine(input);
        ++lineNo;
        if (line.empty()) continue;
        if (const auto cmd = parseCommand(line)) {
            execute(editor, *cmd, out);
        } else {
            ++skipped;
            if (err) *err << "textbuffer: line " << lineNo << ": invalid command: " << line << '\n';
        }
    }
    return skipped;
}

}  // namespace textbuffer
