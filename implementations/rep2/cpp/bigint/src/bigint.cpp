#include "bigint/bigint.hpp"

#include <ostream>

namespace bigint {

BigInt::BigInt(bool negative, mag::Magnitude magnitude)
    : neg_(negative && !magnitude.empty()), mag_(std::move(magnitude)) {}

BigInt::BigInt(std::int64_t value) {
    neg_ = value < 0;
    // Negate in unsigned arithmetic so INT64_MIN is handled.
    std::uint64_t u = neg_ ? 0 - static_cast<std::uint64_t>(value)
                           : static_cast<std::uint64_t>(value);
    while (u != 0) {
        mag_.push_back(static_cast<mag::Limb>(u % mag::kBase));
        u /= mag::kBase;
    }
}

BigInt::BigInt(std::string_view s) {
    bool negative = false;
    if (!s.empty() && s.front() == '-') {
        negative = true;
        s.remove_prefix(1);
    }
    if (s.empty()) throw ParseError("BigInt: empty number");
    for (char c : s) {
        if (c < '0' || c > '9') throw ParseError("BigInt: invalid digit in number");
    }
    mag_ = mag::from_digits(s);
    neg_ = negative && !mag_.empty();
}

std::string BigInt::to_string() const {
    std::string s = mag::to_string(mag_);
    return neg_ ? "-" + s : s;
}

std::uint64_t BigInt::to_uint64() const {
    if (neg_) throw std::overflow_error("BigInt: negative value");
    if (mag_.size() > 3) throw std::overflow_error("BigInt: value too large");
    unsigned __int128 v = 0;
    for (std::size_t i = mag_.size(); i-- > 0;) v = v * mag::kBase + mag_[i];
    if (v > UINT64_MAX) throw std::overflow_error("BigInt: value too large");
    return static_cast<std::uint64_t>(v);
}

BigInt BigInt::operator-() const { return BigInt(!neg_, mag_); }

BigInt BigInt::abs() const { return BigInt(false, mag_); }

BigInt& BigInt::operator+=(const BigInt& rhs) {
    if (neg_ == rhs.neg_) {
        mag_ = mag::add(mag_, rhs.mag_);
    } else {
        const int c = mag::compare(mag_, rhs.mag_);
        if (c == 0) {
            mag_.clear();
            neg_ = false;
        } else if (c > 0) {
            mag_ = mag::sub(mag_, rhs.mag_);
        } else {
            mag_ = mag::sub(rhs.mag_, mag_);
            neg_ = rhs.neg_;
        }
    }
    return *this;
}

BigInt& BigInt::operator-=(const BigInt& rhs) { return *this += -rhs; }

BigInt& BigInt::operator*=(const BigInt& rhs) {
    mag_ = mag::mul(mag_, rhs.mag_);
    neg_ = !mag_.empty() && (neg_ != rhs.neg_);
    return *this;
}

std::pair<BigInt, BigInt> BigInt::divmod(const BigInt& a, const BigInt& b) {
    mag::DivMod r = mag::divmod(a.mag_, b.mag_);
    return {BigInt(a.neg_ != b.neg_, std::move(r.quotient)),
            BigInt(a.neg_, std::move(r.remainder))};
}

BigInt& BigInt::operator/=(const BigInt& rhs) {
    *this = divmod(*this, rhs).first;
    return *this;
}

BigInt& BigInt::operator%=(const BigInt& rhs) {
    *this = divmod(*this, rhs).second;
    return *this;
}

BigInt BigInt::pow(const BigInt& base, std::uint64_t exponent) {
    return BigInt(base.neg_ && (exponent & 1), mag::pow(base.mag_, exponent));
}

int BigInt::compare(const BigInt& a, const BigInt& b) {
    if (a.neg_ != b.neg_) return a.neg_ ? -1 : 1;
    const int c = mag::compare(a.mag_, b.mag_);
    return a.neg_ ? -c : c;
}

std::ostream& operator<<(std::ostream& os, const BigInt& v) { return os << v.to_string(); }

}  // namespace bigint
