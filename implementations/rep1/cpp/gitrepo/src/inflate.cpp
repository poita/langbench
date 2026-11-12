#include "gitrepo/inflate.hpp"

#include <algorithm>
#include <array>
#include <utility>

#include "gitrepo/error.hpp"

namespace gitrepo {

std::uint32_t adler32(std::string_view data) {
  constexpr std::uint32_t kMod = 65521;
  std::uint32_t a = 1, b = 0;
  std::size_t i = 0;
  while (i < data.size()) {
    std::size_t end = std::min(data.size(), i + 5552);  // avoid overflow
    for (; i < end; ++i) {
      a += static_cast<std::uint8_t>(data[i]);
      b += a;
    }
    a %= kMod;
    b %= kMod;
  }
  return (b << 16) | a;
}

namespace {

constexpr int kMaxBits = 15;

/// Canonical Huffman code, decoded bit by bit (RFC 1951 section 3.2.2).
struct Huffman {
  std::array<std::uint16_t, kMaxBits + 1> count{};
  std::array<std::uint16_t, 288> symbol{};

  /// Builds the code from per-symbol lengths. Returns the number of unused
  /// code space: 0 for a complete code, > 0 for an incomplete one, < 0 for an
  /// over-subscribed (invalid) one.
  int build(const std::uint8_t* lengths, int n) {
    count.fill(0);
    for (int i = 0; i < n; ++i) ++count[lengths[i]];
    if (count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= kMaxBits; ++len) {
      left <<= 1;
      left -= count[len];
      if (left < 0) return left;
    }
    std::array<std::uint16_t, kMaxBits + 2> offs{};
    for (int len = 1; len <= kMaxBits; ++len) offs[len + 1] = offs[len] + count[len];
    for (int i = 0; i < n; ++i) {
      if (lengths[i] != 0) symbol[offs[lengths[i]]++] = static_cast<std::uint16_t>(i);
    }
    return left;
  }
};

class Inflater {
 public:
  Inflater(std::string_view in, std::string& out, std::size_t max_output)
      : in_(in), out_(out), start_(out.size()), max_output_(max_output) {}

  /// Inflates the DEFLATE stream; returns the input position after it.
  std::size_t run() {
    bool last;
    do {
      last = bits(1) != 0;
      switch (bits(2)) {
        case 0: stored(); break;
        case 1: fixed(); break;
        case 2: dynamic(); break;
        default: throw Error("inflate: invalid block type");
      }
    } while (!last);
    return pos_;  // fewer than 8 bits are ever buffered, all of the last byte
  }

 private:
  std::uint32_t bits(int need) {
    while (count_ < need) {
      if (pos_ >= in_.size()) throw Error("inflate: unexpected end of input");
      buf_ |= std::uint64_t(static_cast<std::uint8_t>(in_[pos_++])) << count_;
      count_ += 8;
    }
    std::uint32_t v = static_cast<std::uint32_t>(buf_ & ((std::uint64_t(1) << need) - 1));
    buf_ >>= need;
    count_ -= need;
    return v;
  }

  int decode(const Huffman& h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len <= kMaxBits; ++len) {
      code |= static_cast<int>(bits(1));
      int count = h.count[len];
      if (code - count < first) return h.symbol[index + (code - first)];
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw Error("inflate: invalid Huffman code");
  }

  void stored() {
    buf_ = 0;
    count_ = 0;
    if (pos_ + 4 > in_.size()) throw Error("inflate: truncated stored block");
    auto b = [&](std::size_t i) { return std::uint32_t(static_cast<std::uint8_t>(in_[pos_ + i])); };
    std::uint32_t len = b(0) | (b(1) << 8);
    std::uint32_t nlen = b(2) | (b(3) << 8);
    if ((len ^ 0xffffu) != nlen) throw Error("inflate: stored block length mismatch");
    pos_ += 4;
    if (pos_ + len > in_.size()) throw Error("inflate: truncated stored block");
    check_room(len);
    out_.append(in_.data() + pos_, len);
    pos_ += len;
  }

  void check_room(std::size_t extra) {
    if (extra > max_output_ - (out_.size() - start_)) {
      throw Error("inflate: output exceeds expected size");
    }
  }

  void codes(const Huffman& lit, const Huffman& dist) {
    static constexpr std::uint16_t kLenBase[29] = {
        3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23, 27,
        31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
    static constexpr std::uint8_t kLenExtra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
                                                   1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
                                                   4, 4, 4, 4, 5, 5, 5, 5, 0};
    static constexpr std::uint16_t kDistBase[30] = {
        1,   2,   3,   4,   5,   7,    9,    13,   17,   25,
        33,  49,  65,  97,  129, 193,  257,  385,  513,  769,
        1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
    static constexpr std::uint8_t kDistExtra[30] = {0, 0, 0, 0, 1, 1, 2,  2,  3,  3,
                                                    4, 4, 5, 5, 6, 6, 7,  7,  8,  8,
                                                    9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
    for (;;) {
      int sym = decode(lit);
      if (sym < 256) {
        check_room(1);
        out_.push_back(static_cast<char>(sym));
      } else if (sym == 256) {
        return;
      } else {
        sym -= 257;
        if (sym >= 29) throw Error("inflate: invalid length symbol");
        std::size_t len = kLenBase[sym] + bits(kLenExtra[sym]);
        int ds = decode(dist);
        if (ds >= 30) throw Error("inflate: invalid distance symbol");
        std::size_t d = kDistBase[ds] + bits(kDistExtra[ds]);
        if (d > out_.size() - start_) throw Error("inflate: distance too far back");
        check_room(len);
        std::size_t from = out_.size() - d;
        for (std::size_t i = 0; i < len; ++i) out_.push_back(out_[from + i]);
      }
    }
  }

  void fixed() {
    static const std::pair<Huffman, Huffman> tables = [] {
      std::uint8_t lengths[288];
      int i = 0;
      for (; i < 144; ++i) lengths[i] = 8;
      for (; i < 256; ++i) lengths[i] = 9;
      for (; i < 280; ++i) lengths[i] = 7;
      for (; i < 288; ++i) lengths[i] = 8;
      std::pair<Huffman, Huffman> t;
      t.first.build(lengths, 288);
      std::uint8_t dl[30];
      for (auto& l : dl) l = 5;
      t.second.build(dl, 30);
      return t;
    }();
    codes(tables.first, tables.second);
  }

  void dynamic() {
    static constexpr std::uint8_t kOrder[19] = {16, 17, 18, 0, 8,  7, 9,  6, 10, 5,
                                                11, 4,  12, 3, 13, 2, 14, 1, 15};
    int nlen = static_cast<int>(bits(5)) + 257;
    int ndist = static_cast<int>(bits(5)) + 1;
    int ncode = static_cast<int>(bits(4)) + 4;
    if (nlen > 286 || ndist > 30) throw Error("inflate: too many length or distance codes");

    std::uint8_t lengths[320] = {};
    for (int i = 0; i < ncode; ++i) lengths[kOrder[i]] = static_cast<std::uint8_t>(bits(3));
    Huffman lencode;
    if (lencode.build(lengths, 19) != 0) throw Error("inflate: bad code length code");

    int index = 0;
    while (index < nlen + ndist) {
      int sym = decode(lencode);
      if (sym < 16) {
        lengths[index++] = static_cast<std::uint8_t>(sym);
      } else {
        int len = 0, rep;
        if (sym == 16) {
          if (index == 0) throw Error("inflate: repeat with no previous length");
          len = lengths[index - 1];
          rep = 3 + static_cast<int>(bits(2));
        } else if (sym == 17) {
          rep = 3 + static_cast<int>(bits(3));
        } else {
          rep = 11 + static_cast<int>(bits(7));
        }
        if (index + rep > nlen + ndist) throw Error("inflate: too many code lengths");
        while (rep--) lengths[index++] = static_cast<std::uint8_t>(len);
      }
    }
    if (lengths[256] == 0) throw Error("inflate: missing end-of-block code");

    Huffman lit, dist;
    int err = lit.build(lengths, nlen);
    if (err < 0 || (err > 0 && nlen != lit.count[0] + lit.count[1])) {
      throw Error("inflate: bad literal/length code");
    }
    err = dist.build(lengths + nlen, ndist);
    if (err < 0 || (err > 0 && ndist != dist.count[0] + dist.count[1])) {
      throw Error("inflate: bad distance code");
    }
    codes(lit, dist);
  }

  std::string_view in_;
  std::string& out_;
  std::size_t start_;
  std::size_t max_output_;
  std::size_t pos_ = 0;
  std::uint64_t buf_ = 0;
  int count_ = 0;
};

}  // namespace

std::size_t zlib_inflate(std::string_view input, std::string& out, std::size_t max_output) {
  if (input.size() < 2) throw Error("zlib: truncated header");
  unsigned cmf = static_cast<std::uint8_t>(input[0]);
  unsigned flg = static_cast<std::uint8_t>(input[1]);
  if ((cmf & 0x0f) != 8 || (cmf * 256 + flg) % 31 != 0 || (flg & 0x20) != 0) {
    throw Error("zlib: invalid header");
  }
  std::size_t start = out.size();
  Inflater inflater(input.substr(2), out, max_output);
  std::size_t used = 2 + inflater.run();
  if (used + 4 > input.size()) throw Error("zlib: truncated Adler-32 trailer");
  std::uint32_t want = 0;
  for (int i = 0; i < 4; ++i) {
    want = (want << 8) | static_cast<std::uint8_t>(input[used + i]);
  }
  if (adler32(std::string_view(out).substr(start)) != want) {
    throw Error("zlib: Adler-32 mismatch");
  }
  return used + 4;
}

}  // namespace gitrepo
