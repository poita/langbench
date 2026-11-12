// The xorshift* generator of SPEC.md section 25.
#pragma once

#include <cstdint>
#include <vector>

namespace spiremark {

class Rng {
public:
    explicit Rng(std::uint64_t seed = 0) : state_(seed == 0 ? 0x2545F4914F6CDD1DULL : seed) {}

    std::uint64_t next() {
        state_ ^= state_ >> 12;
        state_ ^= state_ << 25;
        state_ ^= state_ >> 27;
        return state_ * 0x2545F4914F6CDD1DULL;
    }
    /// Uniform-ish value in [0, n); n >= 1.
    std::uint64_t below(std::uint64_t n) { return next() % n; }

    /// Fisher-Yates shuffle as specified: i from k-1 down to 1, swap with below(i+1).
    template <class Seq>
    void shuffle(Seq& list) {
        for (std::size_t i = list.size(); i-- > 1;) {
            std::size_t j = static_cast<std::size_t>(below(i + 1));
            std::swap(list[i], list[j]);
        }
    }

private:
    std::uint64_t state_;
};

}  // namespace spiremark
