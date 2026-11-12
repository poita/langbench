#include "qrcode/segment.hpp"

#include <algorithm>
#include <cstdint>
#include <string_view>

namespace qrcode {
namespace {

constexpr std::string_view kAlphanumericChars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

int alphanumericValue(unsigned char c) noexcept {
    auto pos = kAlphanumericChars.find(static_cast<char>(c));
    return pos == std::string_view::npos ? -1 : static_cast<int>(pos);
}

}  // namespace

Mode selectMode(std::string_view text) noexcept {
    bool numeric = true, alnum = true;
    for (unsigned char c : text) {
        if (c < '0' || c > '9') numeric = false;
        if (alphanumericValue(c) < 0) {
            alnum = false;
            break;
        }
    }
    if (numeric) return Mode::Numeric;
    return alnum ? Mode::Alphanumeric : Mode::Byte;
}

unsigned modeIndicator(Mode mode) noexcept {
    switch (mode) {
        case Mode::Numeric: return 1;
        case Mode::Alphanumeric: return 2;
        case Mode::Byte: return 4;
    }
    return 0;
}

int charCountBits(Mode mode, int v) {
    int tier = v <= 9 ? 0 : v <= 26 ? 1 : 2;
    static constexpr int kBits[3][3] = {{10, 12, 14}, {9, 11, 13}, {8, 16, 16}};
    return kBits[static_cast<int>(mode)][tier];
}

std::size_t dataBitLength(Mode mode, std::size_t n) noexcept {
    switch (mode) {
        case Mode::Numeric: {
            static constexpr std::size_t kTail[3] = {0, 4, 7};
            return 10 * (n / 3) + kTail[n % 3];
        }
        case Mode::Alphanumeric: return 11 * (n / 2) + 6 * (n % 2);
        case Mode::Byte: return 8 * n;
    }
    return 0;
}

int chooseVersion(Mode mode, std::size_t count, Ecl ecl) {
    std::size_t data = dataBitLength(mode, count);
    for (int v = kMinVersion; v <= kMaxVersion; ++v) {
        std::size_t need = 4 + static_cast<std::size_t>(charCountBits(mode, v)) + data;
        if (need <= 8 * static_cast<std::size_t>(dataCodewords(ecl, v))) return v;
    }
    return 0;
}

void appendSegment(BitBuffer& out, Mode mode, std::string_view text, int version) {
    out.append(modeIndicator(mode), 4);
    out.append(static_cast<std::uint32_t>(text.size()), charCountBits(mode, version));
    switch (mode) {
        case Mode::Numeric:
            for (std::size_t i = 0; i < text.size();) {
                std::size_t len = std::min<std::size_t>(3, text.size() - i);
                std::uint32_t value = 0;
                for (std::size_t j = 0; j < len; ++j) value = value * 10 + (text[i + j] - '0');
                out.append(value, static_cast<int>(len) * 3 + 1);  // 1->4, 2->7, 3->10 bits
                i += len;
            }
            break;
        case Mode::Alphanumeric:
            for (std::size_t i = 0; i < text.size(); i += 2) {
                std::uint32_t a = static_cast<std::uint32_t>(alphanumericValue(text[i]));
                if (i + 1 < text.size()) {
                    out.append(45 * a + static_cast<std::uint32_t>(alphanumericValue(text[i + 1])), 11);
                } else {
                    out.append(a, 6);
                }
            }
            break;
        case Mode::Byte:
            for (unsigned char c : text) out.append(c, 8);
            break;
    }
}

void terminateAndPad(BitBuffer& bits, Ecl ecl, int version) {
    std::size_t capacity = 8 * static_cast<std::size_t>(dataCodewords(ecl, version));
    bits.appendZeros(std::min<std::size_t>(4, capacity - bits.size()));
    bits.appendZeros((8 - bits.size() % 8) % 8);
    for (std::uint32_t pad = 0xEC; bits.size() < capacity; pad ^= 0xEC ^ 0x11) bits.append(pad, 8);
}

}  // namespace qrcode
