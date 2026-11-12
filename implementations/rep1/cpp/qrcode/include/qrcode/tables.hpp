#pragma once
/// \file tables.hpp
/// Version-dependent constants of QR Code Model 2: capacities, block
/// structure and alignment-pattern positions.

#include <vector>

namespace qrcode {

/// Error correction level.
enum class Ecl { L = 0, M = 1, Q = 2, H = 3 };

inline constexpr int kMinVersion = 1;
inline constexpr int kMaxVersion = 40;

/// Side length in modules of a symbol of version `v`: 4v + 17.
constexpr int symbolSize(int v) { return 4 * v + 17; }

/// Number of modules available for codeword bits (including remainder bits).
int rawDataModules(int v);

/// Total number of codewords (data + error correction): rawDataModules / 8.
int totalCodewords(int v);

/// Error correction codewords in each block.
int eccCodewordsPerBlock(Ecl ecl, int v);

/// Number of Reed-Solomon blocks.
int blockCount(Ecl ecl, int v);

/// Number of data codewords available at version `v` and level `ecl`.
int dataCodewords(Ecl ecl, int v);

/// Alignment pattern centre coordinates (empty for version 1).
const std::vector<int>& alignmentPositions(int v);

}  // namespace qrcode
