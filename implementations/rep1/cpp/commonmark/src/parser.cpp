#include "commonmark/parser.h"

#include "commonmark/commonmark.h"
#include "internal.h"

namespace commonmark {

Document parse(std::string_view markdown) {
  Document doc;
  detail::parse_blocks(doc, markdown);
  detail::parse_inlines(doc);
  return doc;
}

std::string to_html(std::string_view markdown) { return render_html(parse(markdown)); }

}  // namespace commonmark
