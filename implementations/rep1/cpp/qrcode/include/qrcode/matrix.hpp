#pragma once
/// \file matrix.hpp
/// The module grid and everything that draws on it: function patterns,
/// format/version information, zigzag data placement and masking.

#include <cstdint>
#include <span>
#include <vector>

#include "qrcode/tables.hpp"

namespace qrcode {

/// Square grid of dark/light modules plus a flag for function modules.
class Matrix {
public:
    explicit Matrix(int version);

    int version() const noexcept { return version_; }
    int size() const noexcept { return size_; }

    bool dark(int x, int y) const noexcept { return modules_[idx(x, y)] != 0; }
    bool isFunction(int x, int y) const noexcept { return function_[idx(x, y)] != 0; }

    /// Raw row-major module values (0 light, 1 dark), size()*size() bytes.
    const std::uint8_t* data() const noexcept { return modules_.data(); }

    /// Sets a function module (dark or light) and marks it as a function module.
    void setFunction(int x, int y, bool dark) noexcept {
        modules_[idx(x, y)] = dark;
        function_[idx(x, y)] = 1;
    }

    /// Draws finder, timing and alignment patterns, the dark module and
    /// reserves (with placeholder values) the format and version areas.
    void drawFunctionPatterns();

    /// Writes the 15 format bits (both copies) for `ecl` and `mask`.
    void drawFormat(Ecl ecl, int mask);

    /// Places codeword bits along the zigzag path onto non-function modules.
    /// Modules left over (remainder bits) stay light.
    void placeCodewords(std::span<const std::uint8_t> codewords);

    /// XORs mask pattern `mask` (0..7) onto all non-function modules.
    void applyMask(int mask) noexcept;

private:
    std::size_t idx(int x, int y) const noexcept {
        return static_cast<std::size_t>(y) * static_cast<std::size_t>(size_) + static_cast<std::size_t>(x);
    }
    void drawFinder(int cx, int cy);
    void drawAlignment(int cx, int cy);
    void drawVersionInfo();

    int version_;
    int size_;
    std::vector<std::uint8_t> modules_;
    std::vector<std::uint8_t> function_;
};

/// The 15-bit format information word (after XOR with 0x5412).
unsigned formatBits(Ecl ecl, int mask) noexcept;

/// The 18-bit version information word (versions 7..40).
unsigned versionBits(int version) noexcept;

/// True if mask pattern `mask` inverts module (x, y).
bool maskCondition(int mask, int x, int y) noexcept;

}  // namespace qrcode
