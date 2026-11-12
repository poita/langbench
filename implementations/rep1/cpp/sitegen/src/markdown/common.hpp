// Internal helpers and data structures shared by the Markdown translation
// units. Not part of the public API.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace sitegen::md_detail {

// ---------------------------------------------------------------------------
// Character classes (ASCII only).
// ---------------------------------------------------------------------------

/// The `cmark_isspace` set: space, TAB, LF, VT, FF, CR.
inline bool is_space_char(unsigned char c) { return c == ' ' || (c >= 9 && c <= 13); }
inline bool is_space_or_tab(unsigned char c) { return c == ' ' || c == '\t'; }
inline bool is_ascii_punct(unsigned char c) {
  return (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) ||
         (c >= 123 && c <= 126);
}
inline bool is_digit(unsigned char c) { return c >= '0' && c <= '9'; }
inline bool is_alpha(unsigned char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
inline bool is_alnum(unsigned char c) { return is_alpha(c) || is_digit(c); }

// ---------------------------------------------------------------------------
// Text helpers (text.cpp).
// ---------------------------------------------------------------------------

/// Decodes the entity reference whose text starts at `s[i]` (the character
/// right after the `&`). On success appends the decoded text to `out` and
/// returns the number of characters consumed after the `&` (including the
/// `;`); returns 0 when no entity matches.
std::size_t decode_entity_at(std::string_view s, std::size_t i, std::string& out);

/// Replaces every valid entity reference in `s` by its character(s).
std::string decode_entities(std::string_view s);

/// Removes the backslash of every backslash-escaped ASCII punctuation char.
std::string unescape_backslashes(std::string_view s);

/// Appends `s` to `out` with `& < > "` HTML-escaped.
void escape_html(std::string& out, std::string_view s);

/// Appends the URL `s` to `out` the way cmark's `escape_href` does.
void escape_href(std::string& out, std::string_view s);

/// True for destinations cmark refuses to emit (`javascript:` and friends).
bool is_dangerous_url(std::string_view url);

// ---------------------------------------------------------------------------
// Block tree (blocks.cpp).
// ---------------------------------------------------------------------------

enum class BlockKind : std::uint8_t {
  Document,
  BlockQuote,
  List,
  Item,
  Paragraph,
  Heading,
  ThematicBreak,
  CodeBlock,
};

struct Block {
  BlockKind kind = BlockKind::Document;
  int parent = -1;
  int first_child = -1;
  int last_child = -1;
  int next = -1;

  bool open = true;
  bool last_line_blank = false;
  bool last_line_checked = false;
  int start_line = 0;

  // List and list item.
  bool ordered = false;
  char delimiter_or_bullet = 0;  // '.' / ')' for ordered lists, bullet char otherwise
  int start = 0;
  bool tight = false;
  int marker_offset = 0;
  int padding = 0;

  // Heading.
  int level = 0;
  bool setext = false;

  // Code block.
  bool fenced = false;
  char fence_char = 0;
  int fence_length = 0;
  int fence_offset = 0;
  std::string info;

  /// Raw text accumulated for paragraphs, headings and code blocks.
  std::string content;
};

/// Phase 1: builds the block tree of `src`. Index 0 is the document.
void parse_blocks(std::string_view src, std::vector<Block>& blocks);

// ---------------------------------------------------------------------------
// Inline tree (inlines.cpp).
// ---------------------------------------------------------------------------

enum class InlineKind : std::uint8_t {
  Root,
  Text,
  SoftBreak,
  LineBreak,
  Code,
  Emph,
  Strong,
  Link,
  Image,
};

struct Inline {
  InlineKind kind = InlineKind::Text;
  int next = -1;
  int prev = -1;
  int first = -1;
  int last = -1;
  bool has_title = false;
  std::string text;   // Text and Code
  std::string dest;   // Link and Image
  std::string title;  // Link and Image
};

struct InlineTree {
  std::vector<Inline> nodes;  // nodes[0] is the root
};

/// Phase 2: parses the content of a paragraph or heading into `tree`.
void parse_inlines(std::string_view content, InlineTree& tree);

/// Renders the children of the tree's root as HTML.
void render_inlines(const InlineTree& tree, std::string& out);

}  // namespace sitegen::md_detail
