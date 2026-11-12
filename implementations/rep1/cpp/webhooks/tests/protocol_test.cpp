#include <gtest/gtest.h>

#include <string>

#include "webhooks/protocol.hpp"

using namespace webhooks;

namespace {
constexpr char kSecret[] = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
constexpr char kId[] = "msg_p5jXN8AQM9LWM0D4loKWxJek";
constexpr char kPayload[] = "7b2274657374223a20323433323233323331347d";
constexpr char kHeader[] =
    "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d";
}  // namespace

TEST(Protocol, SpecExampleStream) {
  std::string in = "sha256 -\nsha256 616263\nhmac - -\nb64enc 666f6f\nb64urlenc fbff\n"
                   "b64dec 5a6d3976\nb64dec -\nsha256 ABCD\nsha256 abc\nfrobnicate 1\n";
  EXPECT_EQ(run_commands(in),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n"
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n"
            "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad\n"
            "Zm9v\n-_8\n666f6f\n-\nerror\nerror\nerror\n");
}

TEST(Protocol, BlankLinesIgnoredAndLastLineMayLackNewline) {
  EXPECT_EQ(run_commands("\n   \nb64enc 666f6f\n  \nb64enc 66"), "Zm9v\nZg==\n");
}

TEST(Protocol, FieldSpacingErrors) {
  EXPECT_EQ(run_commands("sha256  616263\n sha256 616263\nsha256 616263 \nsha256\tabc\n"),
            "error\nerror\nerror\nerror\n");
}

TEST(Protocol, SecretCommand) {
  EXPECT_EQ(run_commands(std::string("secret ") + kSecret + "\nsecret whsec_\nsecret a,b\n"),
            "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0\nerror\nerror\n");
}

TEST(Protocol, SignAndVerify) {
  std::string base = std::string(kSecret) + " " + kId + " 1614265330 ";
  std::string in = "sign " + base + kPayload + "\n" +
                   "verify " + base + "1614265400 " + kHeader + " " + kPayload + "\n" +
                   "verify " + base + "1614265631 " + kHeader + " " + kPayload + "\n" +
                   "verify " + base + "1614265400 " + kHeader + " 7b7d\n" +
                   "verify " + base + "1614265400 - " + kPayload + "\n" +
                   "sign " + std::string(kSecret) + " " + kId + " 01 " + kPayload + "\n" +
                   "verify " + std::string(kSecret) + " " + kId + " 01 1 " + kHeader + " " + kPayload + "\n";
  EXPECT_EQ(run_commands(in),
            "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=\nok 0 0\nfail timestamp-too-old\n"
            "fail no-match\nfail missing-signature\nerror\nfail invalid-timestamp\n");
}

TEST(Protocol, SimulateExample) {
  std::string in =
      "simulate\n"
      "endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200\n"
      "endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200\n"
      "event msg_1 1700000000 user.created 7b7d\n"
      "event msg_2 1700000100 repo.pushed 7b7d\n"
      "end\n";
  EXPECT_EQ(run_commands(in),
            "sim 5 3\n"
            "attempt 1 msg_1 ep_a 1 1700000000 failure 500\n"
            "attempt 2 msg_1 ep_b 1 1700000000 success 200\n"
            "attempt 3 msg_1 ep_a 2 1700000005 timeout -\n"
            "attempt 4 msg_2 ep_a 1 1700000100 success 200\n"
            "attempt 5 msg_1 ep_a 3 1700000305 success 200\n"
            "delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94=\n"
            "delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= "
            "v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s=\n"
            "delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U=\n");
}

TEST(Protocol, MalformedBlockConsumesUntilEnd) {
  std::string in =
      "simulate\n"
      "endpoint ep_a c2VjcmV0 * 200\n"
      "bogus line\n"
      "event e 1 t 7b7d\n"
      "end\n"
      "b64enc 66\n";
  EXPECT_EQ(run_commands(in), "error\nZg==\n");
}

TEST(Protocol, BlockViolations) {
  const char* bad[] = {
      "simulate\nend\n",                                                       // no endpoint
      "simulate\nevent e 1 t -\nendpoint a c2VjcmV0 * 200\nend\n",              // endpoint after event
      "simulate\nendpoint a c2VjcmV0 * 200\nendpoint a c2VjcmV0 * 200\nend\n",  // duplicate id
      "simulate\nendpoint a c2VjcmV0 * 200\nevent e 1 t -\nevent e 2 t -\nend\n",
      "simulate\nendpoint a c2VjcmV0 * 200\nsimulate\nend\n",
      "simulate\nendpoint a c2VjcmV0 * 200\n",                                  // no end
      "simulate\nendpoint a c2VjcmV0 * 200 extra\nend\n",
      "simulate\nendpoint a c2VjcmV0 * 099\nend\n",
      "simulate\nendpoint a c2VjcmV0 * 200\nevent e 01 t -\nend\n",
      "simulate\nendpoint a c2VjcmV0 * 200\nend x\nend\n",
  };
  for (const char* in : bad) EXPECT_EQ(run_commands(in), "error\n") << in;
}

TEST(Protocol, SimulateWithExtraFieldIsAnOrdinaryErrorLine) {
  EXPECT_EQ(run_commands("simulate now\nend\nendpoint a b c d\nevent a b c d\n"),
            "error\nerror\nerror\nerror\n");
}

TEST(Protocol, EmptyEventListIsValid) {
  EXPECT_EQ(run_commands("simulate\n\nendpoint a c2VjcmV0 * 200\n  \nend\n"), "sim 0 0\n");
}

TEST(Protocol, EventAndEndpointCaps) {
  std::string in = "simulate\n";
  for (int i = 0; i < 64; ++i) in += "endpoint e" + std::to_string(i) + " c2VjcmV0 * 200\n";
  in += "end\n";
  EXPECT_EQ(run_commands(in), "sim 0 0\n");
  in = "simulate\n";
  for (int i = 0; i < 65; ++i) in += "endpoint e" + std::to_string(i) + " c2VjcmV0 * 200\n";
  in += "end\n";
  EXPECT_EQ(run_commands(in), "error\n");

  in = "simulate\nendpoint a c2VjcmV0 * 200\n";
  for (int i = 0; i < 20000; ++i) in += "event v" + std::to_string(i) + " 0 t -\n";
  in += "end\n";
  EXPECT_EQ(run_commands(in).substr(0, 12), "sim 20000 20");
  in = "simulate\nendpoint a c2VjcmV0 * 200\n";
  for (int i = 0; i < 20001; ++i) in += "event v" + std::to_string(i) + " 0 t -\n";
  in += "end\n";
  EXPECT_EQ(run_commands(in), "error\n");
}
