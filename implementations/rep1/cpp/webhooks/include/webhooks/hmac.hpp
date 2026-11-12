/// @file hmac.hpp
/// HMAC-SHA-256 (RFC 2104), implemented on top of webhooks::Sha256.
#pragma once

#include <string_view>

#include "webhooks/bytes.hpp"
#include "webhooks/sha256.hpp"

namespace webhooks {

/// Incremental HMAC-SHA-256.
///
/// Construction absorbs the key (hashing it first when longer than the 64-byte
/// block; an empty key is legal). Copying an object that has not been fed yet
/// is a cheap way to reuse one key for many messages.
class HmacSha256 {
 public:
  static constexpr std::size_t kMacSize = Sha256::kDigestSize;
  using Mac = Sha256::Digest;

  explicit HmacSha256(ByteView key);

  HmacSha256& update(ByteView data) noexcept {
    inner_.update(data);
    return *this;
  }
  HmacSha256& update(std::string_view text) noexcept {
    inner_.update(text);
    return *this;
  }

  /// Returns the MAC. The object must not be fed again afterwards.
  Mac finish() noexcept;

 private:
  Sha256 inner_;
  Sha256 outer_;
};

/// One-shot HMAC-SHA-256.
HmacSha256::Mac hmac_sha256(ByteView key, ByteView message);

/// Compares two byte strings in time independent of where they differ.
bool constant_time_equal(ByteView a, ByteView b) noexcept;

}  // namespace webhooks
