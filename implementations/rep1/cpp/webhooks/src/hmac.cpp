#include "webhooks/hmac.hpp"

#include <array>

namespace webhooks {

HmacSha256::HmacSha256(ByteView key) {
  std::array<std::uint8_t, Sha256::kBlockSize> block{};  // zero padded
  if (key.size() > block.size()) {
    Sha256::Digest hashed = sha256(key);
    std::copy(hashed.begin(), hashed.end(), block.begin());
  } else {
    std::copy(key.begin(), key.end(), block.begin());
  }
  std::array<std::uint8_t, Sha256::kBlockSize> ipad, opad;
  for (std::size_t i = 0; i < block.size(); ++i) {
    ipad[i] = block[i] ^ 0x36;
    opad[i] = block[i] ^ 0x5c;
  }
  inner_.update(ipad);
  outer_.update(opad);
}

HmacSha256::Mac HmacSha256::finish() noexcept {
  Sha256::Digest inner_digest = inner_.finish();
  outer_.update(inner_digest);
  return outer_.finish();
}

HmacSha256::Mac hmac_sha256(ByteView key, ByteView message) {
  HmacSha256 mac(key);
  mac.update(message);
  return mac.finish();
}

bool constant_time_equal(ByteView a, ByteView b) noexcept {
  if (a.size() != b.size()) return false;
  std::uint8_t diff = 0;
  for (std::size_t i = 0; i < a.size(); ++i) diff |= a[i] ^ b[i];
  return diff == 0;
}

}  // namespace webhooks
