#pragma once
/// \file reed_solomon.hpp
/// Reed-Solomon error correction over GF(2^8) (primitive polynomial 0x11D).

#include <cstdint>
#include <span>
#include <vector>

namespace qrcode {

/// Product of two field elements in GF(2^8)/0x11D.
std::uint8_t gfMultiply(std::uint8_t a, std::uint8_t b) noexcept;

/// Systematic Reed-Solomon encoder for a fixed number of ECC codewords.
class ReedSolomon {
public:
    /// Builds the generator polynomial prod_{i<degree}(x - 2^i); 1 <= degree <= 255.
    explicit ReedSolomon(int degree);

    int degree() const noexcept { return static_cast<int>(generator_.size()); }

    /// Remainder of data(x) * x^degree divided by the generator, highest degree first.
    std::vector<std::uint8_t> remainder(std::span<const std::uint8_t> data) const;

private:
    /// Generator coefficients without the leading 1, highest degree first.
    std::vector<std::uint8_t> generator_;
};

}  // namespace qrcode
