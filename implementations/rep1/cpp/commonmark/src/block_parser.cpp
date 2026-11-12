// Phase 1: block structure.
//
// A cmark-style line-by-line block parser. For every line it (1) walks the
// chain of open blocks, checking which of them the line continues, (2) opens
// any new container or leaf blocks that start on the line, and (3) adds the
// remaining text to the open leaf block (or to a lazy paragraph continuation).
// Every scanner looks only at the characters it consumes or inspects.
#include <string>
#include <vector>

#include "internal.h"
#include "text_util.h"

namespace commonmark::detail {
namespace {

constexpr int kCodeIndent = 4;
constexpr int kTabStop = 4;

/// Parser-only bookkeeping for each node, indexed by NodeId.
struct BlockState {
  bool open = true;
  bool last_line_blank = false;
  bool last_line_checked = false;  // memo for the tight/loose test
  bool fenced = false;
  bool setext = false;
  char fence_char = 0;
  int fence_length = 0;
  int fence_offset = 0;
  int marker_offset = 0;  // list items
  int padding = 0;        // list items
  int start_line = 0;
};

bool accepts_lines(NodeType t) {
  return t == NodeType::Paragraph || t == NodeType::Heading || t == NodeType::CodeBlock;
}

bool can_contain(NodeType parent, NodeType child) {
  switch (parent) {
    case NodeType::Document:
    case NodeType::BlockQuote:
    case NodeType::Item:
      return child != NodeType::Item;
    case NodeType::List:
      return child == NodeType::Item;
    default:
      return false;
  }
}

class BlockParser {
 public:
  explicit BlockParser(Document& doc) : doc_(doc) {
    states_.resize(1);
    tip_ = doc_.root();
  }

  void run(std::string_view input) {
    std::size_t pos = 0;
    while (pos < input.size()) {
      const std::size_t nl = input.find('\n', pos);
      if (nl == std::string_view::npos) {
        process_line(input.substr(pos));
        break;
      }
      process_line(input.substr(pos, nl - pos));
      pos = nl + 1;
    }
    // Close everything that is still open.
    while (tip_ != kNoNode) tip_ = finalize(tip_);
  }

 private:
  struct ListMarker {
    ListType type = ListType::None;
    char delimiter = 0;
    int start = 0;
    int width = 0;
  };

  // ---- small helpers -------------------------------------------------------

  BlockState& st(NodeId id) { return states_[static_cast<std::size_t>(id)]; }
  Node& node(NodeId id) { return doc_[id]; }
  NodeType type_of(NodeId id) { return doc_[id].type; }

  char peek(std::size_t i) const { return i < line_.size() ? line_[i] : '\0'; }

  NodeId new_node(NodeType t) {
    const NodeId id = doc_.create(t);
    states_.emplace_back();
    states_.back().start_line = line_number_;
    return id;
  }

  NodeId add_child(NodeId parent, NodeType t) {
    while (!can_contain(type_of(parent), t)) parent = finalize(parent);
    const NodeId id = new_node(t);
    doc_.append_child(parent, id);
    return id;
  }

  // ---- line position tracking ----------------------------------------------

  void find_first_nonspace() {
    first_nonspace_ = offset_;
    first_nonspace_column_ = column_;
    int chars_to_tab = kTabStop - (column_ % kTabStop);
    for (;;) {
      const char c = peek(first_nonspace_);
      if (c == ' ') {
        ++first_nonspace_;
        ++first_nonspace_column_;
        if (--chars_to_tab == 0) chars_to_tab = kTabStop;
      } else if (c == '\t') {
        ++first_nonspace_;
        first_nonspace_column_ += chars_to_tab;
        chars_to_tab = kTabStop;
      } else {
        break;
      }
    }
    indent_ = first_nonspace_column_ - column_;
    blank_ = first_nonspace_ >= line_.size() || peek(first_nonspace_) == '\n';
  }

  /// Advances by `count` characters, or by `count` columns if `columns`.
  void advance_offset(int count, bool columns) {
    while (count > 0 && offset_ < line_.size()) {
      const char c = line_[offset_];
      if (c == '\t') {
        const int chars_to_tab = kTabStop - (column_ % kTabStop);
        if (columns) {
          partially_consumed_tab_ = chars_to_tab > count;
          const int advance = partially_consumed_tab_ ? count : chars_to_tab;
          column_ += advance;
          if (!partially_consumed_tab_) ++offset_;
          count -= advance;
        } else {
          partially_consumed_tab_ = false;
          column_ += chars_to_tab;
          ++offset_;
          --count;
        }
      } else {
        partially_consumed_tab_ = false;
        ++offset_;
        ++column_;
        --count;
      }
    }
  }

  /// Appends the rest of the line (with its '\n') to `id`'s text.
  void add_line(NodeId id) {
    std::string& text = node(id).literal;
    if (partially_consumed_tab_) {
      ++offset_;  // the tab itself
      const int chars_to_tab = kTabStop - (column_ % kTabStop);
      text.append(static_cast<std::size_t>(chars_to_tab), ' ');
    }
    if (offset_ < line_.size()) text.append(line_, offset_, std::string::npos);
  }

  // ---- scanners ------------------------------------------------------------

  /// `#{1,6}` followed by a space/tab or the end of the line at first_nonspace_.
  /// Returns the level, or 0.
  int scan_atx_heading_start() const {
    std::size_t i = first_nonspace_;
    int level = 0;
    while (peek(i) == '#' && level < 7) {
      ++level;
      ++i;
    }
    if (level < 1 || level > 6) return 0;
    const char c = peek(i);
    return (is_space_or_tab(c) || c == '\n' || i >= line_.size()) ? level : 0;
  }

  /// A run of >= 3 backticks (rest of line free of backticks) or tildes.
  /// Returns the run length, or 0.
  int scan_open_code_fence() const {
    const char c = peek(first_nonspace_);
    std::size_t i = first_nonspace_;
    while (peek(i) == c) ++i;
    const int len = static_cast<int>(i - first_nonspace_);
    if (len < 3) return 0;
    if (c == '`') {
      for (; i < line_.size(); ++i) {
        if (line_[i] == '`') return 0;
      }
    }
    return len;
  }

  /// A closing fence of `c` with at least `min_len` characters at
  /// first_nonspace_, followed only by spaces/tabs.
  bool scan_close_code_fence(char c, int min_len) const {
    std::size_t i = first_nonspace_;
    while (peek(i) == c) ++i;
    if (static_cast<int>(i - first_nonspace_) < min_len) return false;
    while (is_space_or_tab(peek(i))) ++i;
    return i >= line_.size() || peek(i) == '\n';
  }

  /// `=+` or `-+` followed by spaces/tabs to the end of the line.
  /// Returns 1 for '=', 2 for '-', 0 otherwise.
  int scan_setext_underline() const {
    const char c = peek(first_nonspace_);
    if (c != '=' && c != '-') return 0;
    std::size_t i = first_nonspace_;
    while (peek(i) == c) ++i;
    while (is_space_or_tab(peek(i))) ++i;
    if (i < line_.size() && peek(i) != '\n') return 0;
    return c == '=' ? 1 : 2;
  }

  /// Three or more of the same `*`, `_` or `-`, optionally separated by
  /// spaces/tabs, to the end of the line.
  bool scan_thematic_break() const {
    const char c = peek(first_nonspace_);
    if (c != '*' && c != '_' && c != '-') return false;
    int count = 0;
    for (std::size_t i = first_nonspace_; i < line_.size(); ++i) {
      const char d = line_[i];
      if (d == c) {
        ++count;
      } else if (!is_space_or_tab(d) && d != '\n') {
        return false;
      }
    }
    return count >= 3;
  }

  /// Parses a list marker at first_nonspace_. Returns false if there is none.
  bool parse_list_marker(bool interrupts_paragraph, ListMarker& out) const {
    std::size_t pos = first_nonspace_;
    char c = peek(pos);
    if (c == '*' || c == '-' || c == '+') {
      ++pos;
      if (!(pos >= line_.size() || is_space(peek(pos)))) return false;
      if (interrupts_paragraph && followed_by_blank(pos)) return false;
      out.type = ListType::Bullet;
      out.delimiter = c;
      out.start = 0;
    } else if (is_digit(c)) {
      int start = 0;
      int digits = 0;
      do {
        start = start * 10 + (peek(pos) - '0');
        ++pos;
        ++digits;
      } while (digits < 9 && is_digit(peek(pos)));
      c = peek(pos);
      if (c != '.' && c != ')') return false;
      ++pos;
      if (!(pos >= line_.size() || is_space(peek(pos)))) return false;
      if (interrupts_paragraph && (start != 1 || followed_by_blank(pos))) return false;
      out.type = ListType::Ordered;
      out.delimiter = c;
      out.start = start;
    } else {
      return false;
    }
    out.width = static_cast<int>(pos - first_nonspace_);
    return true;
  }

  bool followed_by_blank(std::size_t pos) const {
    while (is_space_or_tab(peek(pos))) ++pos;
    return pos >= line_.size() || peek(pos) == '\n';
  }

  // ---- step 1: continuing open blocks --------------------------------------

  bool parse_block_quote_prefix() {
    if (indent_ <= 3 && peek(first_nonspace_) == '>') {
      advance_offset(static_cast<int>(first_nonspace_ - offset_) + 1, false);
      if (is_space_or_tab(peek(offset_))) advance_offset(1, true);
      return true;
    }
    return false;
  }

  bool parse_item_prefix(NodeId item) {
    const BlockState& s = st(item);
    if (indent_ >= s.marker_offset + s.padding) {
      advance_offset(s.marker_offset + s.padding, true);
      return true;
    }
    if (blank_ && node(item).first_child != kNoNode) {
      advance_offset(static_cast<int>(first_nonspace_ - offset_), false);
      return true;
    }
    return false;
  }

  enum class CodePrefix { Fail, Continue, Closed };

  CodePrefix parse_code_block_prefix(NodeId code) {
    const BlockState& s = st(code);
    if (!s.fenced) {
      if (indent_ >= kCodeIndent) {
        advance_offset(kCodeIndent, true);
        return CodePrefix::Continue;
      }
      if (blank_) {
        advance_offset(static_cast<int>(first_nonspace_ - offset_), false);
        return CodePrefix::Continue;
      }
      return CodePrefix::Fail;
    }
    if (indent_ <= 3 && peek(first_nonspace_) == s.fence_char &&
        scan_close_code_fence(s.fence_char, s.fence_length)) {
      return CodePrefix::Closed;
    }
    int i = s.fence_offset;
    while (i > 0 && is_space_or_tab(peek(offset_))) {
      advance_offset(1, true);
      --i;
    }
    return CodePrefix::Continue;
  }

  // ---- the per-line driver -------------------------------------------------

  void process_line(std::string_view raw) {
    line_.assign(raw);
    line_.push_back('\n');
    ++line_number_;
    offset_ = 0;
    column_ = 0;
    partially_consumed_tab_ = false;

    // Step 1: which open blocks does this line continue?
    NodeId container = doc_.root();
    for (;;) {
      const NodeId child = node(container).last_child;
      if (child == kNoNode || !st(child).open) break;
      container = child;
      find_first_nonspace();
      bool ok = true;
      switch (type_of(container)) {
        case NodeType::BlockQuote:
          ok = parse_block_quote_prefix();
          break;
        case NodeType::Item:
          ok = parse_item_prefix(container);
          break;
        case NodeType::CodeBlock:
          switch (parse_code_block_prefix(container)) {
            case CodePrefix::Fail:
              ok = false;
              break;
            case CodePrefix::Continue:
              break;
            case CodePrefix::Closed:
              tip_ = finalize(container);
              return;
          }
          break;
        case NodeType::Heading:
          ok = false;
          break;
        case NodeType::Paragraph:
          ok = !blank_;
          break;
        default:
          break;  // lists and thematic breaks always continue
      }
      if (!ok) {
        container = node(container).parent;
        break;
      }
    }
    const NodeId last_matched = container;

    // Step 2: start new blocks.
    bool maybe_lazy = type_of(tip_) == NodeType::Paragraph;
    while (type_of(container) != NodeType::CodeBlock) {
      find_first_nonspace();
      const bool indented = indent_ >= kCodeIndent;
      const char c = peek(first_nonspace_);
      int level = 0;
      ListMarker marker;

      if (!indented && c == '>') {
        advance_offset(static_cast<int>(first_nonspace_ - offset_) + 1, false);
        if (is_space_or_tab(peek(offset_))) advance_offset(1, true);
        container = add_child(container, NodeType::BlockQuote);
      } else if (!indented && c == '#' && (level = scan_atx_heading_start()) != 0) {
        advance_offset(static_cast<int>(first_nonspace_ - offset_) + level, false);
        while (is_space_or_tab(peek(offset_))) advance_offset(1, false);
        container = add_child(container, NodeType::Heading);
        node(container).level = level;
      } else if (!indented && (c == '`' || c == '~') && (level = scan_open_code_fence()) != 0) {
        const int fence_offset = static_cast<int>(first_nonspace_ - offset_);
        advance_offset(fence_offset + level, false);
        container = add_child(container, NodeType::CodeBlock);
        BlockState& s = st(container);
        s.fenced = true;
        s.fence_char = c;
        s.fence_length = level;
        s.fence_offset = fence_offset;
      } else if (!indented && type_of(container) == NodeType::Paragraph &&
                 (level = scan_setext_underline()) != 0) {
        node(container).type = NodeType::Heading;
        node(container).level = level;
        st(container).setext = true;
        advance_offset(static_cast<int>(line_.size() - 1 - offset_), false);
      } else if (!indented && scan_thematic_break()) {
        container = add_child(container, NodeType::ThematicBreak);
        advance_offset(static_cast<int>(line_.size() - 1 - offset_), false);
      } else if (indent_ < kCodeIndent &&
                 parse_list_marker(type_of(container) == NodeType::Paragraph, marker)) {
        open_list_item(container, marker);
      } else if (indented && !maybe_lazy && !blank_) {
        advance_offset(kCodeIndent, true);
        container = add_child(container, NodeType::CodeBlock);
      } else {
        break;
      }

      if (accepts_lines(type_of(container))) break;
      maybe_lazy = false;
    }

    // Step 3: add the text of the line.
    find_first_nonspace();
    NodeId last_child = node(container).last_child;
    if (blank_ && last_child != kNoNode) st(last_child).last_line_blank = true;
    {
      const NodeType ct = type_of(container);
      const BlockState& s = st(container);
      const bool excluded =
          ct == NodeType::BlockQuote || ct == NodeType::Heading || ct == NodeType::ThematicBreak ||
          (ct == NodeType::CodeBlock && s.fenced) ||
          (ct == NodeType::Item && node(container).first_child == kNoNode &&
           s.start_line == line_number_);
      st(container).last_line_blank = blank_ && !excluded;
      for (NodeId a = node(container).parent; a != kNoNode; a = node(a).parent) {
        st(a).last_line_blank = false;
      }
    }

    if (tip_ != last_matched && container == last_matched && !blank_ &&
        type_of(tip_) == NodeType::Paragraph) {
      add_line(tip_);  // lazy paragraph continuation
      return;
    }
    while (tip_ != last_matched) tip_ = finalize(tip_);

    if (type_of(container) == NodeType::CodeBlock) {
      add_line(container);
    } else if (blank_) {
      // nothing
    } else if (type_of(container) == NodeType::Heading ||
               type_of(container) == NodeType::Paragraph) {
      if (type_of(container) == NodeType::Heading && !st(container).setext) {
        add_atx_heading_text(container);
      } else {
        advance_offset(static_cast<int>(first_nonspace_ - offset_), false);
        add_line(container);
      }
    } else {
      container = add_child(container, NodeType::Paragraph);
      advance_offset(static_cast<int>(first_nonspace_ - offset_), false);
      add_line(container);
    }
    tip_ = container;
  }

  void open_list_item(NodeId& container, const ListMarker& marker) {
    advance_offset(static_cast<int>(first_nonspace_ - offset_) + marker.width, false);

    const std::size_t save_offset = offset_;
    const int save_column = column_;
    const bool save_partial = partially_consumed_tab_;
    while (column_ - save_column <= 5 && is_space_or_tab(peek(offset_))) advance_offset(1, true);
    const int spaces = column_ - save_column;
    int padding;
    if (spaces >= 5 || spaces < 1 || peek(offset_) == '\n' || offset_ >= line_.size()) {
      padding = marker.width + 1;
      offset_ = save_offset;
      column_ = save_column;
      partially_consumed_tab_ = save_partial;
      if (spaces > 0) advance_offset(1, true);
    } else {
      padding = marker.width + spaces;
    }
    const int marker_offset = indent_;

    NodeType ct = type_of(container);
    bool same_list = false;
    if (ct == NodeType::List) {
      const Node& l = node(container);
      same_list = l.list_type == marker.type && l.list_delimiter == marker.delimiter;
    }
    if (!same_list) {
      container = add_child(container, NodeType::List);
      Node& l = node(container);
      l.list_type = marker.type;
      l.list_delimiter = marker.delimiter;
      l.list_start = marker.start;
      l.list_tight = true;
    }
    container = add_child(container, NodeType::Item);
    st(container).marker_offset = marker_offset;
    st(container).padding = padding;
  }

  /// Adds the content of an ATX heading line: strips the optional closing
  /// sequence of `#`s and surrounding whitespace.
  void add_atx_heading_text(NodeId heading) {
    advance_offset(static_cast<int>(first_nonspace_ - offset_), false);
    std::string_view rest(line_);
    std::size_t begin = offset_;
    if (partially_consumed_tab_) ++begin;
    rest = rest.substr(std::min(begin, rest.size()));
    rest = rtrim(rest);
    std::size_t n = rest.size();
    std::size_t k = n;
    while (k > 0 && rest[k - 1] == '#') --k;
    if (k != n && (k == 0 || is_space_or_tab(rest[k - 1]))) {
      rest = rtrim(rest.substr(0, k));
    }
    std::string& text = node(heading).literal;
    if (partially_consumed_tab_ && !rest.empty()) {
      text.append(static_cast<std::size_t>(kTabStop - (column_ % kTabStop)), ' ');
    }
    text.append(rest);
    text.push_back('\n');
  }

  // ---- finalizing blocks -----------------------------------------------------

  NodeId finalize(NodeId b) {
    const NodeId parent = node(b).parent;
    BlockState& s = st(b);
    if (!s.open) return parent;
    s.open = false;
    switch (type_of(b)) {
      case NodeType::CodeBlock:
        finalize_code_block(b);
        break;
      case NodeType::List:
        finalize_list(b);
        break;
      default:
        break;
    }
    return parent;
  }

  void finalize_code_block(NodeId b) {
    Node& n = node(b);
    std::string& content = n.literal;
    if (st(b).fenced) {
      const std::size_t nl = content.find('\n');
      const std::string_view info = std::string_view(content).substr(0, nl);
      n.extra = unescape_backslashes(trim(decode_entities(info)));
      content = nl == std::string::npos ? std::string() : content.substr(nl + 1);
    } else {
      std::size_t i = content.size();
      while (i > 0 && (content[i - 1] == ' ' || content[i - 1] == '\t' || content[i - 1] == '\n')) --i;
      if (i == 0) {
        content.clear();
      } else {
        const std::size_t nl = content.find('\n', i);
        if (nl != std::string::npos) content.resize(nl);
      }
      content.push_back('\n');
    }
  }

  /// cmark's memoised "does this block end with a blank line" test: lists and
  /// items with children defer to their last child; anything else (or a block
  /// already visited) answers with its own flag.
  bool ends_with_blank_line(NodeId id) {
    for (NodeId cur = id;;) {
      BlockState& s = st(cur);
      if (s.last_line_checked) return s.last_line_blank;
      s.last_line_checked = true;
      const NodeType t = type_of(cur);
      const NodeId last = node(cur).last_child;
      if ((t == NodeType::List || t == NodeType::Item) && last != kNoNode) {
        cur = last;
      } else {
        return s.last_line_blank;
      }
    }
  }

  void finalize_list(NodeId list) {
    bool tight = true;
    for (NodeId item = node(list).first_child; item != kNoNode && tight; item = node(item).next) {
      const bool has_next_item = node(item).next != kNoNode;
      if (st(item).last_line_blank && has_next_item) {
        tight = false;
        break;
      }
      for (NodeId sub = node(item).first_child; sub != kNoNode; sub = node(sub).next) {
        if ((has_next_item || node(sub).next != kNoNode) && ends_with_blank_line(sub)) {
          tight = false;
          break;
        }
      }
    }
    node(list).list_tight = tight;
  }

  Document& doc_;
  std::vector<BlockState> states_;
  NodeId tip_ = kNoNode;
  int line_number_ = 0;

  std::string line_;  // current line including its '\n'
  std::size_t offset_ = 0;
  int column_ = 0;
  bool partially_consumed_tab_ = false;
  std::size_t first_nonspace_ = 0;
  int first_nonspace_column_ = 0;
  int indent_ = 0;
  bool blank_ = false;
};

}  // namespace

void parse_blocks(Document& doc, std::string_view input) {
  BlockParser parser(doc);
  parser.run(input);
}

}  // namespace commonmark::detail
