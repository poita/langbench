// The CommonMark 0.31.2 specification examples that fall in the supported
// subset, checked as a table. The data file is generated; see its header.
#include "test_helpers.h"

namespace {

struct Example {
  int number;
  const char* section;
  const char* markdown;
  const char* html;
};

const Example kExamples[] = {
#include "spec_examples_data.inc"
};

}  // namespace

TEST(SpecExamples, AllExamplesRenderAsSpecified) {
  int failures = 0;
  for (const Example& e : kExamples) {
    const std::string actual = commonmark::to_html(e.markdown);
    if (actual != e.html) {
      ++failures;
      ADD_FAILURE() << "example " << e.number << " (" << e.section << ")\nmarkdown:\n"
                    << e.markdown << "\nexpected:\n" << e.html << "\nactual:\n" << actual;
    }
  }
  EXPECT_EQ(failures, 0);
  EXPECT_GT(sizeof(kExamples) / sizeof(kExamples[0]), 400u);
}
