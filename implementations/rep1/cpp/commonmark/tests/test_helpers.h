#ifndef COMMONMARK_TESTS_HELPERS_H
#define COMMONMARK_TESTS_HELPERS_H

#include <gtest/gtest.h>

#include <string>

#include "commonmark/commonmark.h"

// Asserts that `markdown` renders to exactly `expected_html`.
#define EXPECT_HTML(markdown, expected_html) \
  EXPECT_EQ(commonmark::to_html(markdown), std::string(expected_html)) << "input: " << (markdown)

#endif  // COMMONMARK_TESTS_HELPERS_H
