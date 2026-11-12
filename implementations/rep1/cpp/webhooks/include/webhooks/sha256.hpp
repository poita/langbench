/// @file sha256.hpp
/// SHA-256 (FIPS 180-4), implemented from scratch.
#pragma once

#include <array>
#include <cstdint>
#include <string_view>

#include "webhooks/bytes.hpp"

namespace webhooks {

/// Incremental SHA-256 hasher.
///
/// The object is cheap to copy, so a partially fed hasher can serve as a
/// prefix state that is cloned for each message.
class Sha256 {
 public:
  static constexpr std::size_t kDigestSize = 32;
  static constexpr std::size_t kBlockSize = 64;
  using Digest = std::array<std::uint8_t, kDigestSize>;

  Sha256() noexcept { reset(); }

  /// Returns the hasher to its initial state.
  void reset() noexcept;

  /// Feeds more message bytes.
  Sha256& update(ByteView data) noexcept;
  Sha256& update(std::string_view text) noexcept { return update(as_bytes(text)); }

  /// Pads the message and returns the digest. The hasher must be reset()
  /// before it is fed again.
  Digest finish() noexcept;

 private:
  void compress(const std::uint8_t* block) noexcept;

  std::array<std::uint32_t, 8> state_;
  std::array<std::uint8_t, kBlockSize> buffer_;
  std::size_t buffered_;
  std::uint64_t length_;  // total message length in bytes
};

/// One-shot SHA-256.
Sha256::Digest sha256(ByteView data) noexcept;

}  // namespace webhooks
