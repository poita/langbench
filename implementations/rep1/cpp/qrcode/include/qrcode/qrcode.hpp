#pragma once
/// \file qrcode.hpp
/// Public API: encode a UTF-8/byte string as a QR Code Model 2 symbol.
///
/// \code
///   qrcode::Symbol s = qrcode::encode("HELLO WORLD", qrcode::Ecl::M);
///   std::cout << s.toString();
/// \endcode
///
/// Mode selection (numeric, alphanumeric, byte), version selection, Reed-
/// Solomon error correction, masking and penalty scoring follow ISO/IEC 18004
/// as summarised in SPEC.md. A single segment is used and no ECI header is
/// emitted.

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "qrcode/tables.hpp"

namespace qrcode {

/// Pass as the `mask` argument of encode() to choose the mask by penalty score.
inline constexpr int kAutoMask = -1;

/// An encoded symbol: a square grid of dark/light modules.
class Symbol {
public:
    Symbol(int version, Ecl ecl, int mask, std::vector<std::uint8_t> modules);

    int version() const noexcept { return version_; }          ///< 1..40
    Ecl ecl() const noexcept { return ecl_; }                  ///< error correction level
    int mask() const noexcept { return mask_; }                ///< mask pattern used, 0..7
    int size() const noexcept { return size_; }                ///< side length, 4*version + 17

    /// True if the module at column `x`, row `y` (0 = top-left) is dark.
    /// Out-of-range coordinates are light.
    bool dark(int x, int y) const noexcept {
        return x >= 0 && y >= 0 && x < size_ && y < size_ &&
               modules_[static_cast<std::size_t>(y) * static_cast<std::size_t>(size_) + static_cast<std::size_t>(x)];
    }

    /// Text rendering: `size` lines of '#' (dark) and '.' (light), each ending in '\n'.
    std::string toString() const;

private:
    int version_;
    Ecl ecl_;
    int mask_;
    int size_;
    std::vector<std::uint8_t> modules_;
};

/// Encodes `text` (treated as raw bytes) at error correction level `ecl`.
///
/// \param mask  0..7 to force a mask pattern, or kAutoMask to pick the one
///              with the lowest penalty (lowest number on ties).
/// \throws std::invalid_argument if `mask` is out of range.
/// \throws std::length_error if the text does not fit in any version.
Symbol encode(std::string_view text, Ecl ecl, int mask = kAutoMask);

}  // namespace qrcode
