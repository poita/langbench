#include "webhooks/secret.hpp"

#include "webhooks/base64.hpp"

namespace webhooks {

std::optional<Bytes> parse_secret(std::string_view secret) {
  constexpr std::string_view kPrefix = "whsec_";
  if (secret.substr(0, kPrefix.size()) == kPrefix) secret.remove_prefix(kPrefix.size());
  std::optional<Bytes> key = base64_decode(secret);
  if (!key || key->empty()) return std::nullopt;
  return key;
}

}  // namespace webhooks
