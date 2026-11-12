#pragma once
/// \file segment.hpp
/// Mode selection, closed-form bit lengths, version selection and the
/// data bit stream of a single-segment QR payload.

#include <cstddef>
#include <string_view>

#include "qrcode/bit_buffer.hpp"
#include "qrcode/tables.hpp"

namespace qrcode {

enum class Mode { Numeric, Alphanumeric, Byte };

/// Chooses the first applicable mode for the bytes of `text`.
Mode selectMode(std::string_view text) noexcept;

/// 4-bit mode indicator value.
unsigned modeIndicator(Mode mode) noexcept;

/// Width of the character count field for `mode` at version `v`.
int charCountBits(Mode mode, int v);

/// Number of data bits for `count` characters in `mode` (no header).
std::size_t dataBitLength(Mode mode, std::size_t count) noexcept;

/// Smallest version whose capacity holds the segment, or 0 if none does.
int chooseVersion(Mode mode, std::size_t count, Ecl ecl);

/// Appends mode indicator, character count and data bits for `text`.
void appendSegment(BitBuffer& out, Mode mode, std::string_view text, int version);

/// Adds the terminator, zero padding to a byte boundary and 0xEC/0x11 pad
/// codewords so that exactly dataCodewords(ecl, version) codewords exist.
void terminateAndPad(BitBuffer& bits, Ecl ecl, int version);

}  // namespace qrcode
