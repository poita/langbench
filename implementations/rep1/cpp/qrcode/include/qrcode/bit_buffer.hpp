#pragma once
/// \file bit_buffer.hpp
/// Append-only buffer of bits, written most-significant bit first.

#include <cstddef>
#include <cstdint>
#include <vector>

namespace qrcode {

class BitBuffer {
public:
    /// Appends the low `count` bits of `value` (0 <= count <= 32), MSB first.
    void append(std::uint32_t value, int count);

    /// Appends `count` zero bits.
    void appendZeros(std::size_t count);

    /// Number of bits stored.
    std::size_t size() const noexcept { return size_; }

    /// Bit at index `i` (0 = first bit written), as 0 or 1.
    int bit(std::size_t i) const noexcept { return (bytes_[i >> 3] >> (7 - (i & 7))) & 1; }

    /// Packs the bits into bytes; the final byte is zero-padded on the right.
    const std::vector<std::uint8_t>& bytes() const noexcept { return bytes_; }

private:
    std::vector<std::uint8_t> bytes_;
    std::size_t size_ = 0;
};

}  // namespace qrcode
