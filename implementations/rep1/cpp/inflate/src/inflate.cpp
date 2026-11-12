#include "inflate/inflate.hpp"

#include <cstring>

#include "inflate/bit_reader.hpp"
#include "inflate/huffman.hpp"
#include "inflate/tables.hpp"

namespace inflate {
namespace {

constexpr unsigned kLitRootBits = 10;
constexpr unsigned kDistRootBits = 8;
constexpr unsigned kCodeLenRootBits = 7;

/// The fixed-Huffman tables of RFC 1951 section 3.2.6, built once.
struct FixedTables {
  HuffmanTable lit{kLitRootBits};
  HuffmanTable dist{kDistRootBits};
  FixedTables() {
    std::uint8_t l[288];
    for (unsigned i = 0; i < 288; ++i) l[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
    lit.build(l, 288);
    std::uint8_t d[32];
    for (auto& v : d) v = 5;
    dist.build(d, 32);
  }
};

const FixedTables& fixed_tables() {
  static const FixedTables tables;
  return tables;
}

Error code_failure(int rc) {
  return rc == HuffmanTable::kTruncated ? Error::TruncatedInput : Error::InvalidCode;
}

class Decoder {
 public:
  Decoder(const std::uint8_t* data, std::size_t size, std::vector<std::uint8_t>& out,
          const Options& opt)
      : br_(data, size), out_(out), max_output_(opt.max_output) {}

  Error run() {
    out_.clear();
    bool final_block = false;
    while (!final_block) {
      std::uint32_t header;
      if (!br_.read(3, header)) return Error::TruncatedInput;
      final_block = header & 1;
      Error e;
      switch (header >> 1) {
        case 0: e = stored_block(); break;
        case 1: e = codes_block(fixed_tables().lit, fixed_tables().dist, false); break;
        case 2: e = dynamic_block(); break;
        default: return Error::InvalidBlockType;
      }
      if (e != Error::None) return e;
    }
    return br_.whole_bytes_remaining() > 0 ? Error::TrailingData : Error::None;
  }

 private:
  Error stored_block() {
    br_.align_to_byte();
    std::uint32_t len, nlen;
    if (!br_.read(16, len) || !br_.read(16, nlen)) return Error::TruncatedInput;
    if ((len ^ nlen) != 0xFFFF) return Error::StoredLengthMismatch;
    if (br_.whole_bytes_remaining() < len) return Error::TruncatedInput;
    if (len > max_output_ - out_.size()) return Error::OutputLimitExceeded;
    const std::size_t old = out_.size();
    out_.resize(old + len);
    br_.read_aligned_bytes(out_.data() + old, len);
    return Error::None;
  }

  Error dynamic_block() {
    std::uint32_t hlit, hdist, hclen;
    if (!br_.read(5, hlit) || !br_.read(5, hdist) || !br_.read(4, hclen))
      return Error::TruncatedInput;
    if (hlit > 29 || hdist > 29) return Error::TooManyCodes;
    const unsigned n_lit = hlit + 257, n_dist = hdist + 1, total = n_lit + n_dist;

    std::uint8_t cl_lengths[19] = {};
    for (unsigned i = 0; i < hclen + 4; ++i) {
      std::uint32_t v;
      if (!br_.read(3, v)) return Error::TruncatedInput;
      cl_lengths[kCodeLengthOrder[i]] = static_cast<std::uint8_t>(v);
    }
    if (clen_.build(cl_lengths, 19).kind != HuffmanInfo::Kind::Complete)
      return Error::InvalidCodeLengthCode;

    std::uint8_t lengths[286 + 30];
    unsigned i = 0;
    while (i < total) {
      const int sym = clen_.decode(br_);
      if (sym < 0) return code_failure(sym);
      if (sym < 16) {
        lengths[i++] = static_cast<std::uint8_t>(sym);
        continue;
      }
      std::uint32_t extra;
      std::uint8_t value = 0;
      unsigned repeat;
      if (sym == 16) {
        if (i == 0) return Error::InvalidRepeat;
        if (!br_.read(2, extra)) return Error::TruncatedInput;
        value = lengths[i - 1];
        repeat = 3 + extra;
      } else if (sym == 17) {
        if (!br_.read(3, extra)) return Error::TruncatedInput;
        repeat = 3 + extra;
      } else {
        if (!br_.read(7, extra)) return Error::TruncatedInput;
        repeat = 11 + extra;
      }
      if (repeat > total - i) return Error::InvalidRepeat;
      std::memset(lengths + i, value, repeat);
      i += repeat;
    }

    if (lengths[kEndOfBlock] == 0) return Error::InvalidLiteralCode;
    HuffmanInfo li = lit_.build(lengths, n_lit);
    if (li.kind == HuffmanInfo::Kind::OverSubscribed ||
        (li.kind == HuffmanInfo::Kind::Incomplete && !li.single_one_bit_code()))
      return Error::InvalidLiteralCode;
    HuffmanInfo di = dist_.build(lengths + n_lit, n_dist);
    if (di.kind == HuffmanInfo::Kind::OverSubscribed ||
        (di.kind == HuffmanInfo::Kind::Incomplete && di.used != 0 && !di.single_one_bit_code()))
      return Error::InvalidDistanceCode;
    return codes_block(lit_, dist_, di.used == 0);
  }

  /// Decode compressed symbols until end-of-block.
  Error codes_block(const HuffmanTable& lit, const HuffmanTable& dist, bool no_distances) {
    for (;;) {
      const int sym = lit.decode(br_);
      if (sym < 0) return code_failure(sym);
      if (sym < 256) {
        if (out_.size() >= max_output_) return Error::OutputLimitExceeded;
        out_.push_back(static_cast<std::uint8_t>(sym));
        continue;
      }
      if (sym == static_cast<int>(kEndOfBlock)) return Error::None;
      if (sym >= static_cast<int>(kMaxLiteralLengthSymbols)) return Error::InvalidSymbol;

      std::uint32_t extra = 0;
      const unsigned li = sym - 257;
      if (!br_.read(kLengthExtra[li], extra)) return Error::TruncatedInput;
      const std::size_t length = kLengthBase[li] + extra;

      if (no_distances) return Error::NoDistanceCodes;
      const int dsym = dist.decode(br_);
      if (dsym < 0) return code_failure(dsym);
      if (dsym >= static_cast<int>(kMaxDistanceSymbols)) return Error::InvalidSymbol;
      if (!br_.read(kDistExtra[dsym], extra)) return Error::TruncatedInput;
      const std::size_t distance = kDistBase[dsym] + extra;

      if (distance > out_.size()) return Error::DistanceTooFar;
      if (length > max_output_ - out_.size()) return Error::OutputLimitExceeded;
      const std::size_t old = out_.size();
      out_.resize(old + length);
      std::uint8_t* dst = out_.data() + old;
      const std::uint8_t* src = dst - distance;
      if (distance >= length) {
        std::memcpy(dst, src, length);
      } else {
        for (std::size_t k = 0; k < length; ++k) dst[k] = src[k];
      }
    }
  }

  BitReader br_;
  std::vector<std::uint8_t>& out_;
  std::size_t max_output_;
  HuffmanTable lit_{kLitRootBits};
  HuffmanTable dist_{kDistRootBits};
  HuffmanTable clen_{kCodeLenRootBits};
};

}  // namespace

Error inflate(const std::uint8_t* data, std::size_t size, std::vector<std::uint8_t>& out,
              const Options& options) {
  return Decoder(data, size, out, options).run();
}

Result inflate(const std::uint8_t* data, std::size_t size, const Options& options) {
  Result r;
  r.error = inflate(data, size, r.data, options);
  if (!r.ok()) r.data.clear();
  return r;
}

Result inflate(const std::vector<std::uint8_t>& stream, const Options& options) {
  return inflate(stream.data(), stream.size(), options);
}

}  // namespace inflate
