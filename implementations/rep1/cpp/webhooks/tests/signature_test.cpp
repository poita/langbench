#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "webhooks/secret.hpp"
#include "webhooks/signature.hpp"

using namespace webhooks;

namespace {

constexpr std::string_view kSecret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
constexpr std::string_view kId = "msg_p5jXN8AQM9LWM0D4loKWxJek";
constexpr std::string_view kBody = R"({"test": 2432232314})";
constexpr std::string_view kSig = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=";

std::vector<SigningKey> keys_for(std::initializer_list<std::string_view> secrets) {
  std::vector<SigningKey> keys;
  for (auto s : secrets) keys.emplace_back(*parse_secret(s));
  return keys;
}

}  // namespace

TEST(ParseInteger, Canonical) {
  EXPECT_EQ(parse_canonical_integer("0"), 0);
  EXPECT_EQ(parse_canonical_integer("1614265330"), 1614265330);
  EXPECT_EQ(parse_canonical_integer("-5"), -5);
  EXPECT_EQ(parse_canonical_integer("1000000000000000"), kMaxAbsInteger);
  EXPECT_EQ(parse_canonical_integer("-1000000000000000"), -kMaxAbsInteger);
}

TEST(ParseInteger, NonCanonical) {
  for (std::string_view s : {"", "-", "-0", "+5", "007", "00", "1.0", "1e3", " 1", "1 ",
                             "1000000000000001", "99999999999999999999", "--1", "0x10"}) {
    EXPECT_FALSE(parse_canonical_integer(s)) << s;
  }
}

TEST(Sign, PublishedTestVector) {
  auto keys = keys_for({kSecret});
  EXPECT_EQ(sign_header(keys, kId, "1614265330", as_bytes(kBody)), kSig);
}

TEST(Sign, RotationJoinsWithSpaces) {
  auto keys = keys_for({kSecret, "whsec_c2VjcmV0"});
  std::string header = sign_header(keys, kId, "1614265330", as_bytes(kBody));
  EXPECT_EQ(header.size(), 2 * 47 + 1);
  EXPECT_EQ(header.substr(0, 47), kSig);
  EXPECT_EQ(header[47], ' ');
}

TEST(Verify, AcceptsPublishedVector) {
  auto keys = keys_for({kSecret});
  VerifyResult r = verify(keys, kId, "1614265330", kSig, as_bytes(kBody), 1614265400);
  EXPECT_TRUE(r.ok);
  EXPECT_EQ(r.secret_index, 0u);
  EXPECT_EQ(r.token_index, 0u);
}

TEST(Verify, ToleranceIsInclusive) {
  auto keys = keys_for({kSecret});
  auto run = [&](std::int64_t now) {
    return verify(keys, kId, "1614265330", kSig, as_bytes(kBody), now);
  };
  EXPECT_TRUE(run(1614265330 + 300).ok);
  EXPECT_TRUE(run(1614265330 - 300).ok);
  EXPECT_EQ(run(1614265330 + 301).error, VerifyError::kTimestampTooOld);
  EXPECT_EQ(run(1614265330 - 301).error, VerifyError::kTimestampTooNew);
}

TEST(Verify, FailureOrder) {
  auto keys = keys_for({kSecret});
  // Empty header outranks a bad timestamp.
  EXPECT_EQ(verify(keys, kId, "bad", "", as_bytes(kBody), 0).error, VerifyError::kMissingSignature);
  EXPECT_EQ(verify(keys, kId, "bad", "   ", as_bytes(kBody), 0).error,
            VerifyError::kMissingSignature);
  EXPECT_EQ(verify(keys, kId, "0123", kSig, as_bytes(kBody), 0).error,
            VerifyError::kInvalidTimestamp);
  EXPECT_EQ(verify(keys, kId, "1614265330", kSig, as_bytes("{}"), 1614265330).error,
            VerifyError::kNoMatch);
}

TEST(Verify, SkipsGarbageTokensAndCountsEmptyOnes) {
  auto keys = keys_for({kSecret});
  std::string header = "garbage  v1,!!! v2," + std::string(kSig.substr(3)) + " " + std::string(kSig);
  VerifyResult r = verify(keys, kId, "1614265330", header, as_bytes(kBody), 1614265330);
  ASSERT_TRUE(r.ok);
  EXPECT_EQ(r.token_index, 4u);  // "garbage", "", "v1,!!!", "v2,...", sig
}

TEST(Verify, FirstMatchIsBySecretThenToken) {
  auto keys = keys_for({"whsec_c2VjcmV0", kSecret});
  VerifyResult r = verify(keys, kId, "1614265330", kSig, as_bytes(kBody), 1614265330);
  ASSERT_TRUE(r.ok);
  EXPECT_EQ(r.secret_index, 1u);
  EXPECT_EQ(r.token_index, 0u);
}

TEST(Verify, UnpaddedSignatureStillMatches) {
  auto keys = keys_for({kSecret});
  std::string unpadded(kSig.substr(0, kSig.size() - 1));
  EXPECT_TRUE(verify(keys, kId, "1614265330", unpadded, as_bytes(kBody), 1614265330).ok);
}

TEST(Verify, NonCanonicalTimestampTextIsSignedAsIs) {
  // The MAC uses the received text, but a non-canonical timestamp is rejected first.
  auto keys = keys_for({kSecret});
  std::string header = sign_header(keys, kId, "0123", as_bytes(kBody));
  EXPECT_EQ(verify(keys, kId, "0123", header, as_bytes(kBody), 123).error,
            VerifyError::kInvalidTimestamp);
}

TEST(VerifyError, Names) {
  EXPECT_EQ(to_string(VerifyError::kNoMatch), "no-match");
  EXPECT_EQ(to_string(VerifyError::kTimestampTooOld), "timestamp-too-old");
}
