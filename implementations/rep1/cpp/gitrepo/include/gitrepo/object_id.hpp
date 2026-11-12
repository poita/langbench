// A 20-byte SHA-1 object id.
#pragma once

#include <array>
#include <compare>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

namespace gitrepo {

struct ObjectId {
  static constexpr std::size_t kSize = 20;
  static constexpr std::size_t kHexSize = 40;

  std::array<std::uint8_t, kSize> bytes{};

  /// Parses exactly 40 lowercase hexadecimal digits.
  static std::optional<ObjectId> from_hex(std::string_view hex);

  /// Copies 20 raw bytes (e.g. out of a tree entry or a pack).
  static ObjectId from_raw(const char* raw20);

  /// 40 lowercase hexadecimal digits.
  std::string hex() const;

  /// Raw bytes as a string view (20 bytes).
  std::string_view raw() const {
    return {reinterpret_cast<const char*>(bytes.data()), kSize};
  }

  bool is_null() const;

  friend bool operator==(const ObjectId&, const ObjectId&) = default;
  friend auto operator<=>(const ObjectId&, const ObjectId&) = default;
};

struct ObjectIdHash {
  std::size_t operator()(const ObjectId& id) const noexcept {
    std::size_t h = 0;
    for (std::size_t i = 0; i < sizeof(h); ++i) h = (h << 8) | id.bytes[i];
    return h;
  }
};

/// True when `c` is one of 0-9a-f.
inline bool is_lower_hex(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}

}  // namespace gitrepo
