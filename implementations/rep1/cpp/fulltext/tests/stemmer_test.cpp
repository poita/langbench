#include <gtest/gtest.h>

#include <fstream>
#include <string>

#include "fulltext/stemmer.hpp"

using fulltext::porter_stem;

TEST(Stemmer, ShortWordsUnchanged) {
  EXPECT_EQ(porter_stem("a"), "a");
  EXPECT_EQ(porter_stem("is"), "is");
  EXPECT_EQ(porter_stem("us"), "us");
}

TEST(Stemmer, Step1a) {
  EXPECT_EQ(porter_stem("caresses"), "caress");
  EXPECT_EQ(porter_stem("ponies"), "poni");
  EXPECT_EQ(porter_stem("ties"), "ti");
  EXPECT_EQ(porter_stem("caress"), "caress");
  EXPECT_EQ(porter_stem("cats"), "cat");
}

TEST(Stemmer, Step1bSelectsRuleBySuffixAlone) {
  EXPECT_EQ(porter_stem("feed"), "feed");
  EXPECT_EQ(porter_stem("bleed"), "bleed");
  EXPECT_EQ(porter_stem("need"), "need");
  EXPECT_EQ(porter_stem("agreed"), "agre");
  EXPECT_EQ(porter_stem("plastered"), "plaster");
  EXPECT_EQ(porter_stem("bled"), "bled");
  EXPECT_EQ(porter_stem("motoring"), "motor");
  EXPECT_EQ(porter_stem("sing"), "sing");
}

TEST(Stemmer, Step1bCleanup) {
  EXPECT_EQ(porter_stem("conflated"), "conflat");
  EXPECT_EQ(porter_stem("troubled"), "troubl");
  EXPECT_EQ(porter_stem("sized"), "size");
  EXPECT_EQ(porter_stem("hopping"), "hop");
  EXPECT_EQ(porter_stem("tanned"), "tan");
  EXPECT_EQ(porter_stem("falling"), "fall");
  EXPECT_EQ(porter_stem("fizzed"), "fizz");
  EXPECT_EQ(porter_stem("filing"), "file");
  EXPECT_EQ(porter_stem("failing"), "fail");
}

TEST(Stemmer, Step1c) {
  EXPECT_EQ(porter_stem("happy"), "happi");
  EXPECT_EQ(porter_stem("sky"), "sky");
}

TEST(Stemmer, LaterSteps) {
  EXPECT_EQ(porter_stem("relational"), "relat");
  EXPECT_EQ(porter_stem("conditional"), "condit");
  EXPECT_EQ(porter_stem("apology"), "apolog");  // LOGI departure
  EXPECT_EQ(porter_stem("conformable"), "conform");
  EXPECT_EQ(porter_stem("formative"), "form");
  EXPECT_EQ(porter_stem("adoption"), "adopt");
  EXPECT_EQ(porter_stem("probate"), "probat");
  EXPECT_EQ(porter_stem("rate"), "rate");
  EXPECT_EQ(porter_stem("cease"), "ceas");
  EXPECT_EQ(porter_stem("controll"), "control");
  EXPECT_EQ(porter_stem("roll"), "roll");
}

TEST(Stemmer, WorkedStemsFromSpec) {
  const std::pair<const char*, const char*> cases[] = {
      {"running", "run"},        {"runs", "run"},          {"runner", "runner"},
      {"connection", "connect"}, {"connections", "connect"}, {"connecting", "connect"},
      {"cats", "cat"},           {"dogs", "dog"},          {"happiness", "happi"},
      {"happier", "happier"},    {"relational", "relat"},  {"relativity", "rel"},
      {"sensibility", "sensibl"}, {"national", "nation"},  {"controlled", "control"},
      {"abandoned", "abandon"}};
  for (const auto& [word, stem] : cases) EXPECT_EQ(porter_stem(word), stem) << word;
}

// Porter's reference vocabulary, when it is available on disk.
TEST(Stemmer, PorterVocabulary) {
  const std::string dir = FULLTEXT_PORTER_DIR;
  std::ifstream voc(dir + "/voc.txt"), out(dir + "/output.txt");
  if (!voc || !out) GTEST_SKIP() << "Porter vocabulary not found in " << dir;
  std::string word, expected;
  std::size_t n = 0, bad = 0;
  while (std::getline(voc, word) && std::getline(out, expected)) {
    ++n;
    if (porter_stem(word) != expected && bad++ < 10) {
      ADD_FAILURE() << word << ": got " << porter_stem(word) << ", want " << expected;
    }
  }
  EXPECT_EQ(bad, 0u);
  EXPECT_GT(n, 23000u);
}
