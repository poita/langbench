#include <gtest/gtest.h>

#include "webhooks/arguments.hpp"

using namespace webhooks;

TEST(Arguments, SplitFieldsKeepsEmptyFields) {
  EXPECT_EQ(split_fields("a b").size(), 2u);
  EXPECT_EQ(split_fields("a  b").size(), 3u);
  EXPECT_EQ(split_fields(" a").size(), 2u);
  EXPECT_EQ(split_fields("a ").size(), 2u);
}

TEST(Arguments, Hex) {
  EXPECT_EQ(*parse_hex_argument("-"), Bytes{});
  EXPECT_EQ(*parse_hex_argument("00ff"), (Bytes{0, 255}));
  EXPECT_FALSE(parse_hex_argument(""));
  EXPECT_FALSE(parse_hex_argument("ABCD"));
  EXPECT_FALSE(parse_hex_argument("abc"));
  EXPECT_FALSE(parse_hex_argument("zz"));
  EXPECT_FALSE(parse_hex_argument("--"));
}

TEST(Arguments, Secrets) {
  EXPECT_TRUE(parse_secrets_argument("whsec_c2VjcmV0"));
  EXPECT_EQ(parse_secrets_argument("whsec_c2VjcmV0,whsec_b3RoZXI")->size(), 2u);
  EXPECT_FALSE(parse_secrets_argument("whsec_c2VjcmV0,"));
  EXPECT_FALSE(parse_secrets_argument(",whsec_c2VjcmV0"));
  EXPECT_FALSE(parse_secrets_argument("whsec_c2VjcmV0,,whsec_c2VjcmV0"));
  std::string sixteen, seventeen;
  for (int i = 0; i < 17; ++i) {
    if (i < 16) sixteen += (i ? "," : "") + std::string("c2VjcmV0");
    seventeen += (i ? "," : "") + std::string("c2VjcmV0");
  }
  EXPECT_TRUE(parse_secrets_argument(sixteen));
  EXPECT_FALSE(parse_secrets_argument(seventeen));
  EXPECT_FALSE(parse_secrets_argument(std::string(513, 'A')));
  EXPECT_FALSE(parse_secret_argument("c2Vj\tcmV0"));
}

TEST(Arguments, Names) {
  EXPECT_TRUE(is_valid_name("ep_a.b-1"));
  EXPECT_FALSE(is_valid_name(""));
  EXPECT_FALSE(is_valid_name("a b"));
  EXPECT_FALSE(is_valid_name("a,b"));
  EXPECT_FALSE(is_valid_name(std::string(65, 'a')));
  EXPECT_TRUE(is_valid_name(std::string(64, 'a')));
}

TEST(Arguments, Ids) {
  EXPECT_TRUE(is_valid_id("-"));
  EXPECT_FALSE(is_valid_id(""));
  EXPECT_TRUE(is_valid_id(std::string(256, 'a')));
  EXPECT_FALSE(is_valid_id(std::string(257, 'a')));
  EXPECT_FALSE(is_valid_id("a\tb"));
  EXPECT_FALSE(is_valid_timestamp_text(std::string(65, '1')));
}

TEST(Arguments, Filter) {
  Endpoint ep;
  ASSERT_TRUE(parse_filter_argument("*", ep));
  EXPECT_TRUE(ep.match_all);
  ASSERT_TRUE(parse_filter_argument("a.b,c", ep));
  EXPECT_FALSE(ep.match_all);
  EXPECT_EQ(ep.types.size(), 2u);
  EXPECT_FALSE(parse_filter_argument("a,", ep));
  EXPECT_FALSE(parse_filter_argument("*,a", ep));
}

TEST(Arguments, Script) {
  auto s = parse_script_argument("500,timeout,200");
  ASSERT_TRUE(s);
  ASSERT_EQ(s->size(), 3u);
  EXPECT_EQ((*s)[0].code, 500);
  EXPECT_TRUE((*s)[1].timeout);
  EXPECT_FALSE(parse_script_argument("099"));
  EXPECT_FALSE(parse_script_argument("600"));
  EXPECT_FALSE(parse_script_argument("20"));
  EXPECT_FALSE(parse_script_argument("2000"));
  EXPECT_FALSE(parse_script_argument("Timeout"));
  EXPECT_FALSE(parse_script_argument("200,"));
  std::string sixty_four = "200", sixty_five;
  for (int i = 1; i < 64; ++i) sixty_four += ",200";
  sixty_five = sixty_four + ",200";
  EXPECT_TRUE(parse_script_argument(sixty_four));
  EXPECT_FALSE(parse_script_argument(sixty_five));
}
