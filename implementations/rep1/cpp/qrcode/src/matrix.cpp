#include "qrcode/matrix.hpp"

#include <algorithm>
#include <cstdlib>

namespace qrcode {

unsigned formatBits(Ecl ecl, int mask) noexcept {
    static constexpr unsigned kEclBits[4] = {1, 0, 3, 2};  // L, M, Q, H
    unsigned data = (kEclBits[static_cast<int>(ecl)] << 3) | static_cast<unsigned>(mask);
    unsigned rem = data;
    for (int i = 0; i < 10; ++i) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return ((data << 10) | rem) ^ 0x5412;
}

unsigned versionBits(int version) noexcept {
    unsigned v = static_cast<unsigned>(version);
    unsigned rem = v;
    for (int i = 0; i < 12; ++i) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    return (v << 12) | rem;
}

bool maskCondition(int m, int x, int y) noexcept {
    switch (m) {
        case 0: return (x + y) % 2 == 0;
        case 1: return y % 2 == 0;
        case 2: return x % 3 == 0;
        case 3: return (x + y) % 3 == 0;
        case 4: return (x / 3 + y / 2) % 2 == 0;
        case 5: return (x * y) % 2 + (x * y) % 3 == 0;
        case 6: return ((x * y) % 2 + (x * y) % 3) % 2 == 0;
        case 7: return ((x + y) % 2 + (x * y) % 3) % 2 == 0;
    }
    return false;
}

Matrix::Matrix(int version)
    : version_(version),
      size_(symbolSize(version)),
      modules_(static_cast<std::size_t>(size_) * static_cast<std::size_t>(size_), 0),
      function_(modules_.size(), 0) {}

void Matrix::drawFinder(int cx, int cy) {
    for (int dy = -4; dy <= 4; ++dy) {
        for (int dx = -4; dx <= 4; ++dx) {
            int x = cx + dx, y = cy + dy;
            if (x < 0 || y < 0 || x >= size_ || y >= size_) continue;
            int d = std::max(std::abs(dx), std::abs(dy));
            setFunction(x, y, d == 0 || d == 1 || d == 3);
        }
    }
}

void Matrix::drawAlignment(int cx, int cy) {
    for (int dy = -2; dy <= 2; ++dy)
        for (int dx = -2; dx <= 2; ++dx)
            setFunction(cx + dx, cy + dy, std::max(std::abs(dx), std::abs(dy)) != 1);
}

void Matrix::drawVersionInfo() {
    if (version_ < 7) return;
    unsigned bits = versionBits(version_);
    for (int i = 0; i < 18; ++i) {
        bool b = (bits >> i) & 1;
        int a = size_ - 11 + i % 3, c = i / 3;
        setFunction(a, c, b);
        setFunction(c, a, b);
    }
}

void Matrix::drawFunctionPatterns() {
    drawFinder(3, 3);
    drawFinder(size_ - 4, 3);
    drawFinder(3, size_ - 4);

    for (int i = 8; i <= size_ - 9; ++i) {
        setFunction(i, 6, i % 2 == 0);
        setFunction(6, i, i % 2 == 0);
    }

    const std::vector<int>& pos = alignmentPositions(version_);
    for (std::size_t i = 0; i < pos.size(); ++i) {
        for (std::size_t j = 0; j < pos.size(); ++j) {
            bool overlapsFinder = (i == 0 && j == 0) || (i == 0 && j + 1 == pos.size()) ||
                                  (i + 1 == pos.size() && j == 0);
            if (!overlapsFinder) drawAlignment(pos[i], pos[j]);
        }
    }

    drawVersionInfo();
    drawFormat(Ecl::L, 0);  // reserve the format areas
    setFunction(8, size_ - 8, true);
}

void Matrix::drawFormat(Ecl ecl, int mask) {
    unsigned bits = formatBits(ecl, mask);
    auto bit = [&](int i) { return ((bits >> i) & 1) != 0; };
    for (int i = 0; i <= 5; ++i) setFunction(8, i, bit(i));
    setFunction(8, 7, bit(6));
    setFunction(8, 8, bit(7));
    setFunction(7, 8, bit(8));
    for (int i = 9; i < 15; ++i) setFunction(14 - i, 8, bit(i));
    for (int i = 0; i < 8; ++i) setFunction(size_ - 1 - i, 8, bit(i));
    for (int i = 8; i < 15; ++i) setFunction(8, size_ - 15 + i, bit(i));
    setFunction(8, size_ - 8, true);
}

void Matrix::placeCodewords(std::span<const std::uint8_t> codewords) {
    const std::size_t totalBits = codewords.size() * 8;
    std::size_t i = 0;
    for (int right = size_ - 1; right >= 1; right -= 2) {
        if (right == 6) right = 5;
        const bool upward = ((right + 1) & 2) == 0;
        for (int vert = 0; vert < size_; ++vert) {
            int y = upward ? size_ - 1 - vert : vert;
            for (int j = 0; j < 2; ++j) {
                int x = right - j;
                if (function_[idx(x, y)]) continue;
                if (i < totalBits) {
                    modules_[idx(x, y)] = (codewords[i >> 3] >> (7 - (i & 7))) & 1;
                    ++i;
                }
            }
        }
    }
}

void Matrix::applyMask(int mask) noexcept {
    for (int y = 0; y < size_; ++y)
        for (int x = 0; x < size_; ++x)
            if (!function_[idx(x, y)] && maskCondition(mask, x, y)) modules_[idx(x, y)] ^= 1;
}

}  // namespace qrcode
