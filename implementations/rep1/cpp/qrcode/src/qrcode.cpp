#include "qrcode/qrcode.hpp"

#include <limits>
#include <utility>
#include <stdexcept>

#include "qrcode/codewords.hpp"
#include "qrcode/matrix.hpp"
#include "qrcode/penalty.hpp"
#include "qrcode/segment.hpp"

namespace qrcode {

Symbol::Symbol(int version, Ecl ecl, int mask, std::vector<std::uint8_t> modules)
    : version_(version), ecl_(ecl), mask_(mask), size_(symbolSize(version)), modules_(std::move(modules)) {}

std::string Symbol::toString() const {
    std::string out;
    out.reserve(static_cast<std::size_t>(size_) * static_cast<std::size_t>(size_ + 1));
    for (int y = 0; y < size_; ++y) {
        for (int x = 0; x < size_; ++x) out.push_back(dark(x, y) ? '#' : '.');
        out.push_back('\n');
    }
    return out;
}

Symbol encode(std::string_view text, Ecl ecl, int mask) {
    if (mask != kAutoMask && (mask < 0 || mask > 7)) throw std::invalid_argument("mask must be 0..7 or auto");

    const Mode mode = selectMode(text);
    const int version = chooseVersion(mode, text.size(), ecl);
    if (version == 0) throw std::length_error("text does not fit in any QR version at this level");

    BitBuffer bits;
    appendSegment(bits, mode, text, version);
    terminateAndPad(bits, ecl, version);
    const std::vector<std::uint8_t> codewords = addEccAndInterleave(bits.bytes(), ecl, version);

    Matrix base(version);
    base.drawFunctionPatterns();
    base.placeCodewords(codewords);

    auto finish = [&](int m) {
        Matrix result = base;
        result.applyMask(m);
        result.drawFormat(ecl, m);
        return result;
    };

    if (mask != kAutoMask) {
        Matrix m = finish(mask);
        return Symbol(version, ecl, mask, std::vector<std::uint8_t>(m.data(), m.data() + m.size() * m.size()));
    }

    int bestMask = 0, bestPenalty = std::numeric_limits<int>::max();
    Matrix best = base;
    for (int m = 0; m < 8; ++m) {
        Matrix candidate = finish(m);
        int p = penaltyScore(candidate);
        if (p < bestPenalty) {
            bestPenalty = p;
            bestMask = m;
            best = std::move(candidate);
        }
    }
    return Symbol(version, ecl, bestMask, std::vector<std::uint8_t>(best.data(), best.data() + best.size() * best.size()));
}

}  // namespace qrcode
