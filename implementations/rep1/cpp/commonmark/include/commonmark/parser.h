// commonmark/parser.h - Markdown text to document tree.
#ifndef COMMONMARK_PARSER_H
#define COMMONMARK_PARSER_H

#include <string_view>

#include "commonmark/node.h"

namespace commonmark {

/// Parses `markdown` into a document tree.
///
/// The parse is a two-phase, cmark-style conversion: block structure is built
/// line by line, then the raw text of each paragraph and heading is parsed
/// into inline nodes. Input is expected to be UTF-8 with LF line endings; it
/// supports the CommonMark subset described in the README (no raw HTML, no
/// link reference definitions, four named entities). Never throws on any
/// input apart from `std::bad_alloc`.
Document parse(std::string_view markdown);

}  // namespace commonmark

#endif  // COMMONMARK_PARSER_H
