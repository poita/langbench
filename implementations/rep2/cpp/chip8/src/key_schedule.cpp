#include "chip8/key_schedule.hpp"

#include <stdexcept>
#include <string>

#include "chip8/program.hpp"

namespace chip8 {

KeySchedule parse_key_schedule(std::string_view text) {
    KeySchedule events;
    std::size_t pos = 0;
    while (pos < text.size()) {
        std::size_t end = text.find(' ', pos);
        if (end == std::string_view::npos) end = text.size();
        const std::string_view tok = text.substr(pos, end - pos);
        pos = end + 1;
        if (tok.empty()) continue;

        const std::size_t colon = tok.find(':');
        if (colon == std::string_view::npos || colon == 0 || tok.size() - colon - 1 != 4)
            throw std::invalid_argument("bad key event: " + std::string(tok));
        const std::uint64_t cycle = detail::parse_decimal(tok.substr(0, colon));
        std::uint16_t mask = 0;
        for (char c : tok.substr(colon + 1)) {
            const int d = detail::hex_digit(c);
            if (d < 0) throw std::invalid_argument("bad key mask: " + std::string(tok));
            mask = static_cast<std::uint16_t>((mask << 4) | d);
        }
        if (!events.empty() && cycle <= events.back().cycle)
            throw std::invalid_argument("key events must be strictly increasing: " + std::string(tok));
        events.push_back({cycle, mask});
    }
    return events;
}

}  // namespace chip8
