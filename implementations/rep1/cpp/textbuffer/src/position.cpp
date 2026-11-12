#include "textbuffer/position.hpp"

#include <algorithm>

namespace textbuffer {

Position advance(Position start, std::string_view text) {
    const auto lines = static_cast<std::uint32_t>(std::count(text.begin(), text.end(), '\n'));
    if (lines == 0) {
        return {start.line, start.col + static_cast<std::uint32_t>(text.size())};
    }
    const auto lastNewline = text.rfind('\n');
    return {start.line + lines, static_cast<std::uint32_t>(text.size() - lastNewline - 1)};
}

}  // namespace textbuffer
