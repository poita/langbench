/// @file markdown.hpp
/// A from-scratch converter for the CommonMark subset used by sitegen.
#pragma once

#include <string>
#include <string_view>

namespace sitegen {

/// Converts Markdown to HTML.
///
/// The supported subset is: thematic breaks, ATX and setext headings,
/// indented and fenced code blocks, paragraphs, block quotes, lists, backslash
/// escapes, entity references (`&amp; &lt; &gt; &quot;` and numeric ones),
/// code spans, emphasis and strong emphasis, inline links and images,
/// autolinks, and hard/soft line breaks. HTML blocks, raw inline HTML,
/// reference links and all extensions are not supported.
///
/// The output matches what `cmark` 0.31.2 produces for the subset: a
/// non-empty document yields HTML ending in a newline, an empty document
/// yields the empty string. The input must be UTF-8 with LF line endings.
///
/// The conversion is linear in the size of the input (apart from the
/// document nesting depth) and never throws on well-formed UTF-8 input.
std::string markdown_to_html(std::string_view markdown);

}  // namespace sitegen
