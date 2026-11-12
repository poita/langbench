#pragma once
/// \file codewords.hpp
/// Splitting data codewords into blocks, adding error correction and
/// interleaving (SPEC section 6).

#include <cstdint>
#include <span>
#include <vector>

#include "qrcode/tables.hpp"

namespace qrcode {

/// Returns the final codeword sequence (interleaved data, then interleaved ECC).
/// `data` must hold exactly dataCodewords(ecl, version) codewords.
std::vector<std::uint8_t> addEccAndInterleave(std::span<const std::uint8_t> data, Ecl ecl, int version);

}  // namespace qrcode
