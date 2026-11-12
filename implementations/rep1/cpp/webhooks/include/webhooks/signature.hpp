/// @file signature.hpp
/// The Standard Webhooks signature scheme: signing and verification.
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "webhooks/bytes.hpp"
#include "webhooks/hmac.hpp"

namespace webhooks {

/// Maximum accepted clock difference between a timestamp and `now`, seconds.
inline constexpr std::int64_t kTimestampToleranceSeconds = 300;

/// Largest absolute value of a canonical timestamp / integer argument.
inline constexpr std::int64_t kMaxAbsInteger = 1'000'000'000'000'000;  // 10^15

/// Parses a canonical decimal integer: `0`, or an optional `-` followed by a
/// digit 1-9 and more digits, with absolute value at most 10^15.
/// `+5`, `007`, `-0`, `1e3` and the empty string are rejected.
std::optional<std::int64_t> parse_canonical_integer(std::string_view text);

/// An HMAC key prepared for repeated signing of `id.timestamp.body`.
class SigningKey {
 public:
  /// Prepares @p key (any length, including empty) for use.
  explicit SigningKey(ByteView key) : prototype_(key) {}

  /// HMAC-SHA-256 of `utf8(id) "." ascii(timestamp) "." body`.
  HmacSha256::Mac mac(std::string_view id, std::string_view timestamp, ByteView body) const;

  /// `"v1," + base64(mac(...))`.
  std::string sign(std::string_view id, std::string_view timestamp, ByteView body) const;

 private:
  HmacSha256 prototype_;
};

/// Builds the `webhook-signature` header: one `v1,<base64>` per key, in key
/// order, joined by single spaces.
std::string sign_header(std::span<const SigningKey> keys, std::string_view id,
                        std::string_view timestamp, ByteView body);

/// Why a verification failed.
enum class VerifyError {
  kMissingSignature,
  kInvalidTimestamp,
  kTimestampTooOld,
  kTimestampTooNew,
  kNoMatch,
};

/// Stable kebab-case name of @p error (e.g. `timestamp-too-old`).
std::string_view to_string(VerifyError error) noexcept;

/// Outcome of verify().
struct VerifyResult {
  bool ok = false;
  std::size_t secret_index = 0;  ///< valid when ok: index of the matching key
  std::size_t token_index = 0;   ///< valid when ok: index of the matching header token
  VerifyError error = VerifyError::kNoMatch;  ///< valid when !ok
};

/// Verifies a received webhook.
///
/// @param keys       active keys, in order
/// @param id         received `webhook-id`
/// @param timestamp  received `webhook-timestamp` text (need not be canonical)
/// @param header     received `webhook-signature` value (split on spaces)
/// @param body       received payload
/// @param now        current Unix time in seconds
///
/// Steps run in the order of SPEC.md §2.3. Costs one MAC per key plus one
/// Base64 decode per header token.
VerifyResult verify(std::span<const SigningKey> keys, std::string_view id,
                    std::string_view timestamp, std::string_view header, ByteView body,
                    std::int64_t now);

}  // namespace webhooks
