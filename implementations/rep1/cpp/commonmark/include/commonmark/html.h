// commonmark/html.h - document tree to HTML.
#ifndef COMMONMARK_HTML_H
#define COMMONMARK_HTML_H

#include <string>

#include "commonmark/node.h"

namespace commonmark {

/// Renders `doc` as HTML in the style of the reference implementation cmark
/// (one block per line, `<hr />`, `<br />`, unsafe URL schemes dropped).
/// Rendering is iterative, so arbitrarily deep trees are fine.
std::string render_html(const Document& doc);

}  // namespace commonmark

#endif  // COMMONMARK_HTML_H
