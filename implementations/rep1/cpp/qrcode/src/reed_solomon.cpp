#include "qrcode/reed_solomon.hpp"

#include <stdexcept>

namespace qrcode {

std::uint8_t gfMultiply(std::uint8_t a, std::uint8_t b) noexcept {
    unsigned z = 0;
    for (int i = 7; i >= 0; --i) {
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((b >> i) & 1u) * a;
    }
    return static_cast<std::uint8_t>(z);
}

ReedSolomon::ReedSolomon(int degree) {
    if (degree < 1 || degree > 255) throw std::invalid_argument("Reed-Solomon degree out of range");
    generator_.assign(static_cast<std::size_t>(degree), 0);
    generator_.back() = 1;  // start with the polynomial "1"
    std::uint8_t root = 1;
    for (int i = 0; i < degree; ++i) {
        // Multiply the current polynomial by (x - root).
        for (std::size_t j = 0; j < generator_.size(); ++j) {
            generator_[j] = gfMultiply(generator_[j], root);
            if (j + 1 < generator_.size()) generator_[j] ^= generator_[j + 1];
        }
        root = gfMultiply(root, 2);
    }
}

std::vector<std::uint8_t> ReedSolomon::remainder(std::span<const std::uint8_t> data) const {
    std::vector<std::uint8_t> result(generator_.size(), 0);
    for (std::uint8_t b : data) {
        std::uint8_t factor = b ^ result.front();
        result.erase(result.begin());
        result.push_back(0);
        if (factor == 0) continue;
        for (std::size_t i = 0; i < result.size(); ++i) result[i] ^= gfMultiply(generator_[i], factor);
    }
    return result;
}

}  // namespace qrcode
