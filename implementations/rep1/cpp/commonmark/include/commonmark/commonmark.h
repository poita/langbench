// commonmark/commonmark.h - umbrella header and one-call convenience API.
//
//   #include <commonmark/commonmark.h>
//   std::string html = commonmark::to_html("# Hello *world*");
#ifndef COMMONMARK_COMMONMARK_H
#define COMMONMARK_COMMONMARK_H

#include <string>
#include <string_view>

#include "commonmark/html.h"
#include "commonmark/node.h"
#include "commonmark/parser.h"

namespace commonmark {

/// Converts Markdown to HTML: `render_html(parse(markdown))`.
std::string to_html(std::string_view markdown);

}  // namespace commonmark

#endif  // COMMONMARK_COMMONMARK_H
