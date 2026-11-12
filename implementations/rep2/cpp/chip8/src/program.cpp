#include "chip8/program.hpp"

#include <stdexcept>

namespace chip8 {

namespace detail {

int hex_digit(char c) noexcept {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::uint64_t parse_decimal(std::string_view s) {
    if (s.empty() || s.size() > 19) throw std::invalid_argument("bad decimal: " + std::string(s));
    std::uint64_t v = 0;
    for (char c : s) {
        if (c < '0' || c > '9') throw std::invalid_argument("bad decimal: " + std::string(s));
        v = v * 10 + static_cast<unsigned>(c - '0');
    }
    return v;
}

}  // namespace detail

namespace {

std::string_view strip_cr(std::string_view s) {
    while (!s.empty() && (s.back() == '\r' || s.back() == ' ')) s.remove_suffix(1);
    return s;
}

}  // namespace

Program parse_program(std::string_view text) {
    std::vector<std::string_view> lines;
    std::size_t pos = 0;
    while (pos <= text.size() && lines.size() < 4) {
        std::size_t nl = text.find('\n', pos);
        if (nl == std::string_view::npos) nl = text.size();
        lines.push_back(strip_cr(text.substr(pos, nl - pos)));
        pos = nl + 1;
    }
    if (lines.size() < 2) throw std::invalid_argument("expected a ROM line and a cycle-count line");

    Program p;
    const std::string_view hex = lines[0];
    if (hex.empty() || hex.size() % 2 != 0) throw std::invalid_argument("ROM must have an even, non-zero number of hex digits");
    if (hex.size() / 2 > kMaxRomSize) throw std::invalid_argument("ROM too large");
    p.rom.reserve(hex.size() / 2);
    for (std::size_t i = 0; i < hex.size(); i += 2) {
        const int hi = detail::hex_digit(hex[i]);
        const int lo = detail::hex_digit(hex[i + 1]);
        if (hi < 0 || lo < 0) throw std::invalid_argument("non-hex character in ROM");
        p.rom.push_back(static_cast<std::uint8_t>(hi * 16 + lo));
    }

    p.cycles = detail::parse_decimal(lines[1]);
    if (lines.size() >= 3) p.keys = parse_key_schedule(lines[2]);
    return p;
}

std::string format_state(const Machine& m) {
    static const char* digits = "0123456789abcdef";
    auto hex = [](std::string& out, unsigned v, int width) {
        for (int s = (width - 1) * 4; s >= 0; s -= 4) out.push_back(digits[(v >> s) & 0xF]);
    };

    std::string out = m.display().to_string();
    out += "PC=";
    hex(out, m.pc(), 4);
    out += " I=";
    hex(out, m.index(), 4);
    out += " SP=" + std::to_string(m.sp());
    out += " DT=";
    hex(out, m.delay_timer(), 2);
    out += " ST=";
    hex(out, m.sound_timer(), 2);
    out += "\nV=";
    for (std::size_t i = 0; i < 16; ++i) {
        if (i) out.push_back(' ');
        hex(out, m.reg(i), 2);
    }
    out.push_back('\n');
    return out;
}

}  // namespace chip8
