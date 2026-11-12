#include "qrcode/codewords.hpp"

#include <stdexcept>

#include "qrcode/reed_solomon.hpp"

namespace qrcode {

std::vector<std::uint8_t> addEccAndInterleave(std::span<const std::uint8_t> data, Ecl ecl, int version) {
    if (data.size() != static_cast<std::size_t>(dataCodewords(ecl, version)))
        throw std::invalid_argument("wrong number of data codewords");

    const std::size_t numBlocks = static_cast<std::size_t>(blockCount(ecl, version));
    const std::size_t eccLen = static_cast<std::size_t>(eccCodewordsPerBlock(ecl, version));
    const std::size_t total = static_cast<std::size_t>(totalCodewords(version));
    const std::size_t numShort = numBlocks - total % numBlocks;
    const std::size_t shortLen = total / numBlocks - eccLen;

    ReedSolomon rs(static_cast<int>(eccLen));
    std::vector<std::span<const std::uint8_t>> blocks;
    std::vector<std::vector<std::uint8_t>> ecc;
    std::size_t pos = 0;
    for (std::size_t i = 0; i < numBlocks; ++i) {
        std::size_t len = shortLen + (i < numShort ? 0 : 1);
        blocks.push_back(data.subspan(pos, len));
        ecc.push_back(rs.remainder(blocks.back()));
        pos += len;
    }

    std::vector<std::uint8_t> out;
    out.reserve(total);
    for (std::size_t i = 0; i <= shortLen; ++i)
        for (std::size_t b = 0; b < numBlocks; ++b)
            if (i < blocks[b].size()) out.push_back(blocks[b][i]);
    for (std::size_t i = 0; i < eccLen; ++i)
        for (std::size_t b = 0; b < numBlocks; ++b) out.push_back(ecc[b][i]);
    return out;
}

}  // namespace qrcode
