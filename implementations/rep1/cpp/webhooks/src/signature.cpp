#include "webhooks/signature.hpp"

#include "webhooks/base64.hpp"

namespace webhooks {

std::optional<std::int64_t> parse_canonical_integer(std::string_view text) {
  if (text == "0") return 0;
  bool negative = false;
  if (!text.empty() && text.front() == '-') {
    negative = true;
    text.remove_prefix(1);
  }
  if (text.empty() || text.size() > 16 || text.front() < '1' || text.front() > '9') {
    return std::nullopt;
  }
  std::int64_t value = 0;
  for (char c : text) {
    if (c < '0' || c > '9') return std::nullopt;
    value = value * 10 + (c - '0');
  }
  if (value > kMaxAbsInteger) return std::nullopt;
  return negative ? -value : value;
}

HmacSha256::Mac SigningKey::mac(std::string_view id, std::string_view timestamp,
                                ByteView body) const {
  HmacSha256 h = prototype_;
  h.update(id).update(".").update(timestamp).update(".").update(body);
  return h.finish();
}

std::string SigningKey::sign(std::string_view id, std::string_view timestamp,
                             ByteView body) const {
  HmacSha256::Mac m = mac(id, timestamp, body);
  return "v1," + base64_encode(m);
}

std::string sign_header(std::span<const SigningKey> keys, std::string_view id,
                        std::string_view timestamp, ByteView body) {
  std::string header;
  for (std::size_t i = 0; i < keys.size(); ++i) {
    if (i > 0) header.push_back(' ');
    header += keys[i].sign(id, timestamp, body);
  }
  return header;
}

std::string_view to_string(VerifyError error) noexcept {
  switch (error) {
    case VerifyError::kMissingSignature: return "missing-signature";
    case VerifyError::kInvalidTimestamp: return "invalid-timestamp";
    case VerifyError::kTimestampTooOld: return "timestamp-too-old";
    case VerifyError::kTimestampTooNew: return "timestamp-too-new";
    case VerifyError::kNoMatch: return "no-match";
  }
  return "no-match";
}

namespace {

VerifyResult failure(VerifyError e) {
  VerifyResult r;
  r.ok = false;
  r.error = e;
  return r;
}

}  // namespace

VerifyResult verify(std::span<const SigningKey> keys, std::string_view id,
                    std::string_view timestamp, std::string_view header, ByteView body,
                    std::int64_t now) {
  // Step 1: split the header on single spaces.
  std::vector<std::string_view> tokens;
  bool any_nonempty = false;
  for (std::size_t start = 0;;) {
    std::size_t end = header.find(' ', start);
    std::string_view tok = header.substr(start, end == std::string_view::npos ? end : end - start);
    tokens.push_back(tok);
    if (!tok.empty()) any_nonempty = true;
    if (end == std::string_view::npos) break;
    start = end + 1;
  }
  if (!any_nonempty) return failure(VerifyError::kMissingSignature);

  // Step 2: the timestamp must be canonical.
  std::optional<std::int64_t> ts = parse_canonical_integer(timestamp);
  if (!ts) return failure(VerifyError::kInvalidTimestamp);

  // Step 3: tolerance window (inclusive).
  if (now - *ts > kTimestampToleranceSeconds) return failure(VerifyError::kTimestampTooOld);
  if (*ts - now > kTimestampToleranceSeconds) return failure(VerifyError::kTimestampTooNew);

  // Step 4: decode every `v1,` token once, then compare against one MAC per key.
  std::vector<std::optional<Bytes>> decoded(tokens.size());
  for (std::size_t j = 0; j < tokens.size(); ++j) {
    std::size_t comma = tokens[j].find(',');
    if (comma == std::string_view::npos) continue;
    if (tokens[j].substr(0, comma) != "v1") continue;
    decoded[j] = base64_decode(tokens[j].substr(comma + 1));
  }
  for (std::size_t i = 0; i < keys.size(); ++i) {
    HmacSha256::Mac expected = keys[i].mac(id, timestamp, body);
    for (std::size_t j = 0; j < tokens.size(); ++j) {
      if (decoded[j] && constant_time_equal(*decoded[j], expected)) {
        VerifyResult r;
        r.ok = true;
        r.secret_index = i;
        r.token_index = j;
        return r;
      }
    }
  }
  return failure(VerifyError::kNoMatch);
}

}  // namespace webhooks
