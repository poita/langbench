#include "bigint/magnitude.hpp"

#include <algorithm>
#include <stdexcept>

namespace bigint::mag {

namespace {
using Wide = std::uint64_t;
using SWide = std::int64_t;
}  // namespace

void trim(Magnitude& m) {
    while (!m.empty() && m.back() == 0) m.pop_back();
}

Magnitude from_digits(std::string_view digits) {
    Magnitude out;
    out.reserve(digits.size() / kBaseDigits + 1);
    std::size_t end = digits.size();
    while (end > 0) {
        const std::size_t begin = end >= kBaseDigits ? end - kBaseDigits : 0;
        Limb limb = 0;
        for (std::size_t i = begin; i < end; ++i) {
            limb = limb * 10 + static_cast<Limb>(digits[i] - '0');
        }
        out.push_back(limb);
        end = begin;
    }
    trim(out);
    return out;
}

std::string to_string(const Magnitude& m) {
    if (m.empty()) return "0";
    std::string s;
    s.reserve(m.size() * kBaseDigits);
    s += std::to_string(m.back());
    char buf[kBaseDigits];
    for (std::size_t i = m.size() - 1; i-- > 0;) {
        Limb v = m[i];
        for (int d = kBaseDigits - 1; d >= 0; --d) {
            buf[d] = static_cast<char>('0' + v % 10);
            v /= 10;
        }
        s.append(buf, kBaseDigits);
    }
    return s;
}

int compare(const Magnitude& a, const Magnitude& b) {
    if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
    for (std::size_t i = a.size(); i-- > 0;) {
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

Magnitude add(const Magnitude& a, const Magnitude& b) {
    const Magnitude& big = a.size() >= b.size() ? a : b;
    const Magnitude& small = a.size() >= b.size() ? b : a;
    Magnitude out;
    out.reserve(big.size() + 1);
    Limb carry = 0;
    for (std::size_t i = 0; i < big.size(); ++i) {
        Limb s = big[i] + carry + (i < small.size() ? small[i] : 0);
        carry = s >= kBase;
        if (carry) s -= kBase;
        out.push_back(s);
    }
    if (carry) out.push_back(1);
    return out;
}

Magnitude sub(const Magnitude& a, const Magnitude& b) {
    Magnitude out;
    out.reserve(a.size());
    Limb borrow = 0;
    for (std::size_t i = 0; i < a.size(); ++i) {
        const Limb sub_by = (i < b.size() ? b[i] : 0) + borrow;
        if (a[i] >= sub_by) {
            out.push_back(a[i] - sub_by);
            borrow = 0;
        } else {
            out.push_back(a[i] + kBase - sub_by);
            borrow = 1;
        }
    }
    trim(out);
    return out;
}

Magnitude mul(const Magnitude& a, const Magnitude& b) {
    if (a.empty() || b.empty()) return {};
    Magnitude out(a.size() + b.size(), 0);
    for (std::size_t i = 0; i < a.size(); ++i) {
        const Wide ai = a[i];
        if (ai == 0) continue;
        Wide carry = 0;
        Limb* row = out.data() + i;
        for (std::size_t j = 0; j < b.size(); ++j) {
            // ai*bj + row + carry <= (B-1)^2 + 2(B-1) < 2^64.
            const Wide cur = row[j] + ai * b[j] + carry;
            carry = cur / kBase;
            row[j] = static_cast<Limb>(cur - carry * kBase);
        }
        row[b.size()] = static_cast<Limb>(carry);
    }
    trim(out);
    return out;
}

Magnitude square(const Magnitude& a) {
    const std::size_t n = a.size();
    if (n == 0) return {};
    // Accumulate each cross product a[i]*a[j] (i<j) once, double, add squares.
    Magnitude out(2 * n, 0);
    for (std::size_t i = 0; i + 1 < n; ++i) {
        const Wide ai = a[i];
        Wide carry = 0;
        for (std::size_t j = i + 1; j < n; ++j) {
            const Wide cur = out[i + j] + ai * a[j] + carry;
            carry = cur / kBase;
            out[i + j] = static_cast<Limb>(cur - carry * kBase);
        }
        out[i + n] = static_cast<Limb>(carry);  // slot untouched so far
    }
    // Double the cross terms.
    Limb carry = 0;
    for (std::size_t k = 0; k < out.size(); ++k) {
        Limb v = out[k] * 2 + carry;  // < 2B + 1 fits in uint32 (< 4.29e9)
        carry = v >= kBase;
        if (carry) v -= kBase;
        out[k] = v;
    }
    // Add the diagonal squares.
    Wide c = 0;
    for (std::size_t i = 0; i < n; ++i) {
        const Wide sq = static_cast<Wide>(a[i]) * a[i];
        Wide lo = out[2 * i] + sq % kBase + c;
        c = lo / kBase;
        lo -= c * kBase;
        out[2 * i] = static_cast<Limb>(lo);
        Wide hi = out[2 * i + 1] + sq / kBase + c;
        c = hi / kBase;
        hi -= c * kBase;
        out[2 * i + 1] = static_cast<Limb>(hi);
    }
    trim(out);
    return out;
}

namespace {

// Divides a by a single limb d (> 0).
DivMod divmod_small(const Magnitude& a, Limb d) {
    DivMod r;
    r.quotient.assign(a.size(), 0);
    Wide rem = 0;
    for (std::size_t i = a.size(); i-- > 0;) {
        const Wide cur = rem * kBase + a[i];
        r.quotient[i] = static_cast<Limb>(cur / d);
        rem = cur % d;
    }
    trim(r.quotient);
    if (rem != 0) r.remainder.push_back(static_cast<Limb>(rem));
    return r;
}

// a * f for a single limb f < kBase, result has a.size()+1 limbs (untrimmed).
Magnitude mul_small_padded(const Magnitude& a, Limb f) {
    Magnitude out(a.size() + 1);
    Wide carry = 0;
    for (std::size_t i = 0; i < a.size(); ++i) {
        const Wide cur = static_cast<Wide>(a[i]) * f + carry;
        carry = cur / kBase;
        out[i] = static_cast<Limb>(cur - carry * kBase);
    }
    out[a.size()] = static_cast<Limb>(carry);
    return out;
}

}  // namespace

DivMod divmod(const Magnitude& a, const Magnitude& b) {
    if (b.empty()) throw std::domain_error("division by zero");
    if (compare(a, b) < 0) return {{}, a};
    if (b.size() == 1) return divmod_small(a, b[0]);

    // Knuth, TAOCP vol. 2, 4.3.1, Algorithm D.
    const std::size_t n = b.size();
    const std::size_t m = a.size() - n;

    // D1: normalise so the divisor's top limb is >= kBase/2.
    const Limb d = static_cast<Limb>(kBase / (static_cast<Wide>(b.back()) + 1));
    Magnitude u = mul_small_padded(a, d);  // a.size()+1 limbs
    Magnitude v = mul_small_padded(b, d);  // top limb is zero
    v.pop_back();

    const Wide vtop = v[n - 1];
    const Wide vsecond = v[n - 2];

    Magnitude q(m + 1, 0);
    for (std::size_t j = m + 1; j-- > 0;) {
        // D3: estimate the quotient digit.
        const Wide num = static_cast<Wide>(u[j + n]) * kBase + u[j + n - 1];
        Wide qhat = num / vtop;
        Wide rhat = num - qhat * vtop;
        while (qhat >= kBase || qhat * vsecond > rhat * kBase + u[j + n - 2]) {
            --qhat;
            rhat += vtop;
            if (rhat >= kBase) break;
        }

        // D4: multiply and subtract.
        SWide borrow = 0;
        Wide carry = 0;
        for (std::size_t i = 0; i < n; ++i) {
            const Wide p = qhat * v[i] + carry;
            carry = p / kBase;
            const SWide t = static_cast<SWide>(u[i + j]) - borrow -
                            static_cast<SWide>(p - carry * kBase);
            if (t < 0) {
                u[i + j] = static_cast<Limb>(t + kBase);
                borrow = 1;
            } else {
                u[i + j] = static_cast<Limb>(t);
                borrow = 0;
            }
        }
        const SWide t = static_cast<SWide>(u[j + n]) - borrow - static_cast<SWide>(carry);
        if (t < 0) {
            // D6: qhat was one too large; add the divisor back.
            u[j + n] = static_cast<Limb>(t + kBase);
            --qhat;
            Limb c = 0;
            for (std::size_t i = 0; i < n; ++i) {
                Limb s = u[i + j] + v[i] + c;
                c = s >= kBase;
                if (c) s -= kBase;
                u[i + j] = s;
            }
            // Carry out cancels the earlier borrow.
            u[j + n] = static_cast<Limb>((u[j + n] + c) % kBase);
        } else {
            u[j + n] = static_cast<Limb>(t);
        }
        q[j] = static_cast<Limb>(qhat);
    }

    // D8: un-normalise the remainder.
    u.resize(n);
    trim(u);
    trim(q);
    Magnitude rem = divmod_small(u, d).quotient;
    return {std::move(q), std::move(rem)};
}

Magnitude pow(const Magnitude& a, std::uint64_t e) {
    Magnitude result{1};
    if (e == 0) return result;
    Magnitude base = a;
    for (;;) {
        if (e & 1) result = mul(result, base);
        e >>= 1;
        if (e == 0) break;  // avoid a wasted (and oversized) final squaring
        base = square(base);
    }
    return result;
}

}  // namespace bigint::mag
