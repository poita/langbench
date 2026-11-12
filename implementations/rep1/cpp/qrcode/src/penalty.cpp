#include "qrcode/penalty.hpp"

#include <cstdint>
#include <cstdlib>

namespace qrcode {
namespace {

constexpr unsigned kFinderLikeA = 0b10111010000;  // #.###.#....
constexpr unsigned kFinderLikeB = 0b00001011101;  // ....#.###.#

/// N1 and N3 for one line of n modules read with the given stride.
void scoreLine(const std::uint8_t* p, std::ptrdiff_t stride, int n, int& n1, int& n3) {
    int run = 1;
    unsigned window = 0;
    for (int i = 0; i < n; ++i) {
        std::uint8_t cur = p[i * stride];
        if (i > 0) {
            if (cur == p[(i - 1) * stride]) {
                ++run;
            } else {
                if (run >= 5) n1 += 3 + (run - 5);
                run = 1;
            }
        }
        window = ((window << 1) | cur) & 0x7FF;
        if (i >= 10) {
            if (window == kFinderLikeA) n3 += 40;
            if (window == kFinderLikeB) n3 += 40;
        }
    }
    if (run >= 5) n1 += 3 + (run - 5);
}

}  // namespace

int penaltyScore(const Matrix& m) {
    const int n = m.size();
    const std::uint8_t* d = m.data();
    int n1 = 0, n2 = 0, n3 = 0;

    for (int i = 0; i < n; ++i) {
        scoreLine(d + static_cast<std::ptrdiff_t>(i) * n, 1, n, n1, n3);  // row i
        scoreLine(d + i, n, n, n1, n3);                                    // column i
    }

    long dark = 0;
    for (int y = 0; y < n; ++y) {
        const std::uint8_t* row = d + static_cast<std::ptrdiff_t>(y) * n;
        for (int x = 0; x < n; ++x) dark += row[x];
        if (y + 1 < n) {
            const std::uint8_t* next = row + n;
            for (int x = 0; x + 1 < n; ++x)
                if (row[x] == row[x + 1] && row[x] == next[x] && row[x] == next[x + 1]) n2 += 3;
        }
    }

    long total = static_cast<long>(n) * n;
    long k = std::labs(20 * dark - 10 * total) / total;
    return n1 + n2 + n3 + static_cast<int>(10 * k);
}

}  // namespace qrcode
