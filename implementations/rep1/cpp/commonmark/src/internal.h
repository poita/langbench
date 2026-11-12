// Internal entry points connecting the parsing phases. Not a public header.
#ifndef COMMONMARK_INTERNAL_H
#define COMMONMARK_INTERNAL_H

#include <string_view>

#include "commonmark/node.h"

namespace commonmark::detail {

/// Phase 1: builds the block tree of `doc` (paragraph and heading nodes keep
/// their raw text in `literal`).
void parse_blocks(Document& doc, std::string_view input);

/// Phase 2: parses the raw text of every paragraph and heading into inline
/// child nodes.
void parse_inlines(Document& doc);

}  // namespace commonmark::detail

#endif  // COMMONMARK_INTERNAL_H
