// Phase 1 of the Markdown conversion: the line-driven block parser.
//
// This follows the structure of cmark's `blocks.c` as described in the
// project's Markdown specification: each line first continues the chain of
// open blocks, then may open new blocks, then contributes its text to the
// innermost open block.
#include <algorithm>

#include "common.hpp"

namespace sitegen::md_detail {

namespace {

class BlockParser {
 public:
  explicit BlockParser(std::vector<Block>& blocks) : b_(blocks) {}

  void run(std::string_view src) {
    b_.clear();
    b_.emplace_back();  // the document
    current_ = 0;

    std::size_t pos = 0;
    while (pos < src.size()) {
      const std::size_t nl = src.find('\n', pos);
      if (nl == std::string_view::npos) {
        process_line(src.substr(pos));
        break;
      }
      process_line(src.substr(pos, nl - pos));
      pos = nl + 1;
    }
    while (current_ != 0) current_ = finalize(current_);
    finalize(0);
  }

 private:
  struct ListData {
    bool ordered = false;
    char delimiter_or_bullet = 0;
    int start = 0;
  };

  // ---- Block tree helpers -------------------------------------------------

  Block& blk(int i) { return b_[static_cast<std::size_t>(i)]; }

  static bool can_contain(BlockKind parent, BlockKind child) {
    switch (parent) {
      case BlockKind::Document:
      case BlockKind::BlockQuote:
      case BlockKind::Item:
        return child != BlockKind::Item;
      case BlockKind::List:
        return child == BlockKind::Item;
      default:
        return false;
    }
  }

  static bool accepts_lines(BlockKind k) {
    return k == BlockKind::Paragraph || k == BlockKind::Heading || k == BlockKind::CodeBlock;
  }

  /// Adds a new open block as the last child of `parent`, first closing
  /// `parent` (and then its parent...) while it cannot hold the new block.
  int add_child(int parent, BlockKind kind) {
    while (!can_contain(blk(parent).kind, kind)) parent = finalize(parent);
    const int idx = static_cast<int>(b_.size());
    b_.emplace_back();
    Block& nb = b_.back();
    nb.kind = kind;
    nb.parent = parent;
    nb.start_line = line_no_;
    Block& p = blk(parent);
    if (p.last_child >= 0) blk(p.last_child).next = idx;
    else p.first_child = idx;
    p.last_child = idx;
    return idx;
  }

  bool ends_with_blank_line(int node) {
    int cur = node;
    while (cur >= 0) {
      Block& c = blk(cur);
      if (c.last_line_checked) return c.last_line_blank;
      c.last_line_checked = true;
      if ((c.kind == BlockKind::List || c.kind == BlockKind::Item) && c.last_child >= 0) {
        cur = c.last_child;
      } else {
        return c.last_line_blank;
      }
    }
    return false;
  }

  /// Closes one block (not its descendants) and returns its parent.
  int finalize(int idx) {
    Block& b = blk(idx);
    b.open = false;
    switch (b.kind) {
      case BlockKind::CodeBlock:
        if (!b.fenced) {
          // Remove trailing blank lines, then end with exactly one newline.
          std::size_t i = b.content.size();
          while (i > 0) {
            const char c = b.content[i - 1];
            if (c != ' ' && c != '\t' && c != '\n') break;
            --i;
          }
          if (i == 0) {
            b.content.clear();
          } else {
            const std::size_t nl = b.content.find('\n', i - 1);
            if (nl != std::string::npos) b.content.resize(nl);
          }
          b.content.push_back('\n');
        } else {
          std::size_t eol = b.content.find('\n');
          if (eol == std::string::npos) eol = b.content.size();
          std::string info = decode_entities(std::string_view(b.content).substr(0, eol));
          std::size_t s = 0, e = info.size();
          while (s < e && is_space_char(static_cast<unsigned char>(info[s]))) ++s;
          while (e > s && is_space_char(static_cast<unsigned char>(info[e - 1]))) --e;
          b.info = unescape_backslashes(std::string_view(info).substr(s, e - s));
          b.content.erase(0, std::min(eol + 1, b.content.size()));
        }
        break;
      case BlockKind::List: {
        b.tight = true;
        for (int item = b.first_child; item >= 0 && b.tight; item = blk(item).next) {
          if (blk(item).last_line_blank && blk(item).next >= 0) {
            b.tight = false;
            break;
          }
          for (int sub = blk(item).first_child; sub >= 0; sub = blk(sub).next) {
            if ((blk(item).next >= 0 || blk(sub).next >= 0) && ends_with_blank_line(sub)) {
              b.tight = false;
              break;
            }
          }
        }
        break;
      }
      default:
        break;
    }
    return b.parent;
  }

  // ---- Line state ---------------------------------------------------------

  char at(int i) const {
    return i >= 0 && i < static_cast<int>(line_.size()) ? line_[static_cast<std::size_t>(i)] : '\n';
  }
  bool at_end(int i) const { return i >= static_cast<int>(line_.size()); }

  void find_first_nonspace() {
    first_nonspace_ = offset_;
    first_nonspace_column_ = column_;
    int chars_to_tab = 4 - (column_ % 4);
    while (!at_end(first_nonspace_)) {
      const char c = at(first_nonspace_);
      if (c == ' ') {
        ++first_nonspace_;
        ++first_nonspace_column_;
        if (--chars_to_tab == 0) chars_to_tab = 4;
      } else if (c == '\t') {
        ++first_nonspace_;
        first_nonspace_column_ += chars_to_tab;
        chars_to_tab = 4;
      } else {
        break;
      }
    }
    indent_ = first_nonspace_column_ - column_;
    blank_ = at_end(first_nonspace_);
  }

  void advance_offset(int count, bool columns) {
    while (count > 0 && !at_end(offset_)) {
      const char c = at(offset_);
      if (c == '\t') {
        const int chars_to_tab = 4 - (column_ % 4);
        if (columns) {
          partial_ = chars_to_tab > count;
          const int adv = partial_ ? count : chars_to_tab;
          column_ += adv;
          if (!partial_) ++offset_;
          count -= adv;
        } else {
          partial_ = false;
          column_ += chars_to_tab;
          ++offset_;
          --count;
        }
      } else {
        partial_ = false;
        ++offset_;
        ++column_;
        --count;
      }
    }
  }

  // ---- Step 1: continuing open blocks -------------------------------------

  bool parse_block_quote_prefix() {
    if (indent_ <= 3 && !blank_ && at(first_nonspace_) == '>') {
      advance_offset(first_nonspace_ + 1 - offset_, false);
      if (is_space_or_tab(static_cast<unsigned char>(at_end(offset_) ? 'x' : at(offset_)))) {
        advance_offset(1, true);
      }
      return true;
    }
    return false;
  }

  bool parse_item_prefix(const Block& item) {
    if (indent_ >= item.marker_offset + item.padding) {
      advance_offset(item.marker_offset + item.padding, true);
      return true;
    }
    if (blank_ && item.first_child >= 0) {
      advance_offset(first_nonspace_ - offset_, false);
      return true;
    }
    return false;
  }

  /// Returns false when the block does not continue. `keep_going` is set to
  /// false when the line has been fully consumed (a closing fence).
  bool parse_code_block_prefix(int idx, bool& keep_going) {
    const Block& cb = blk(idx);
    if (!cb.fenced) {
      if (indent_ >= 4) {
        advance_offset(4, true);
        return true;
      }
      if (blank_) {
        advance_offset(first_nonspace_ - offset_, false);
        return true;
      }
      return false;
    }
    if (indent_ <= 3 && !blank_ && at(first_nonspace_) == cb.fence_char) {
      int p = first_nonspace_;
      int run = 0;
      while (!at_end(p) && at(p) == cb.fence_char) {
        ++p;
        ++run;
      }
      while (!at_end(p) && is_space_or_tab(static_cast<unsigned char>(at(p)))) ++p;
      if (run >= cb.fence_length && at_end(p)) {
        keep_going = false;
        current_ = finalize(idx);
        return false;
      }
    }
    int i = cb.fence_offset;
    while (i > 0 && !at_end(offset_) && is_space_or_tab(static_cast<unsigned char>(at(offset_)))) {
      advance_offset(1, true);
      --i;
    }
    return true;
  }

  // ---- Step 2: starting new blocks ----------------------------------------

  /// Level of an ATX heading starting at `p`, or 0.
  int scan_atx_heading(int p) const {
    int n = 0;
    while (at(p + n) == '#' && !at_end(p + n)) ++n;
    if (n < 1 || n > 6) return 0;
    const int q = p + n;
    if (at_end(q) || is_space_or_tab(static_cast<unsigned char>(at(q)))) return n;
    return 0;
  }

  /// Length of an opening code fence starting at `p`, or 0.
  int scan_open_fence(int p) const {
    if (at_end(p)) return 0;
    const char c = at(p);
    if (c != '`' && c != '~') return 0;
    int n = 0;
    while (!at_end(p + n) && at(p + n) == c) ++n;
    if (n < 3) return 0;
    if (c == '`') {
      for (int q = p + n; !at_end(q); ++q) {
        if (at(q) == '`') return 0;
      }
    }
    return n;
  }

  /// 1 for `=` underlines, 2 for `-` underlines, 0 otherwise.
  int scan_setext_underline(int p) const {
    if (at_end(p)) return 0;
    const char c = at(p);
    if (c != '=' && c != '-') return 0;
    int q = p;
    while (!at_end(q) && at(q) == c) ++q;
    while (!at_end(q) && is_space_or_tab(static_cast<unsigned char>(at(q)))) ++q;
    if (!at_end(q)) return 0;
    return c == '=' ? 1 : 2;
  }

  bool scan_thematic_break(int p) const {
    if (at_end(p)) return false;
    const char c = at(p);
    if (c != '*' && c != '_' && c != '-') return false;
    int count = 0;
    for (int q = p; !at_end(q); ++q) {
      const char d = at(q);
      if (d == c) ++count;
      else if (!is_space_or_tab(static_cast<unsigned char>(d))) return false;
    }
    return count >= 3;
  }

  /// Parses a list marker at `p`. On success returns true with the marker
  /// width in `width`.
  bool parse_list_marker(int p, bool interrupts_paragraph, ListData& data, int& width) const {
    if (at_end(p)) return false;
    const char c = at(p);
    int pos = p;
    auto after_ok = [&](int q) {
      return at_end(q) || is_space_or_tab(static_cast<unsigned char>(at(q)));
    };
    auto rest_blank = [&](int q) {
      while (!at_end(q) && is_space_or_tab(static_cast<unsigned char>(at(q)))) ++q;
      return at_end(q);
    };
    if (c == '*' || c == '-' || c == '+') {
      ++pos;
      if (!after_ok(pos)) return false;
      if (interrupts_paragraph && rest_blank(pos)) return false;
      data.ordered = false;
      data.delimiter_or_bullet = c;
      data.start = 0;
      width = 1;
      return true;
    }
    if (is_digit(static_cast<unsigned char>(c))) {
      int start = 0, digits = 0;
      while (!at_end(pos) && is_digit(static_cast<unsigned char>(at(pos)))) {
        start = start * 10 + (at(pos) - '0');
        ++pos;
        if (++digits > 9) return false;
      }
      if (at_end(pos) || (at(pos) != '.' && at(pos) != ')')) return false;
      const char delim = at(pos);
      ++pos;
      if (!after_ok(pos)) return false;
      if (interrupts_paragraph && (start != 1 || rest_blank(pos))) return false;
      data.ordered = true;
      data.delimiter_or_bullet = delim;
      data.start = start;
      width = pos - p;
      return true;
    }
    return false;
  }

  void open_new_blocks(int& container, bool all_matched) {
    (void)all_matched;
    bool maybe_lazy = blk(current_).kind == BlockKind::Paragraph;
    while (blk(container).kind != BlockKind::CodeBlock) {
      find_first_nonspace();
      const bool indented = indent_ >= 4;
      int n = 0;
      ListData data;
      int width = 0;
      const char c = blank_ ? '\n' : at(first_nonspace_);

      if (!indented && c == '>') {
        advance_offset(first_nonspace_ + 1 - offset_, false);
        if (!at_end(offset_) && is_space_or_tab(static_cast<unsigned char>(at(offset_)))) {
          advance_offset(1, true);
        }
        container = add_child(container, BlockKind::BlockQuote);
      } else if (!indented && c == '#' && (n = scan_atx_heading(first_nonspace_)) != 0) {
        advance_offset(first_nonspace_ + n - offset_, false);
        container = add_child(container, BlockKind::Heading);
        blk(container).level = n;
      } else if (!indented && (c == '`' || c == '~') && (n = scan_open_fence(first_nonspace_)) != 0) {
        const int fence_offset = first_nonspace_ - offset_;
        container = add_child(container, BlockKind::CodeBlock);
        Block& cb = blk(container);
        cb.fenced = true;
        cb.fence_char = c;
        cb.fence_length = n;
        cb.fence_offset = fence_offset;
        advance_offset(first_nonspace_ + n - offset_, false);
      } else if (!indented && blk(container).kind == BlockKind::Paragraph &&
                 (n = scan_setext_underline(first_nonspace_)) != 0) {
        Block& para = blk(container);
        para.kind = BlockKind::Heading;
        para.level = n;
        para.setext = true;
        advance_offset(static_cast<int>(line_.size()) - offset_, false);
      } else if (!indented && scan_thematic_break(first_nonspace_)) {
        container = add_child(container, BlockKind::ThematicBreak);
        advance_offset(static_cast<int>(line_.size()) - offset_, false);
      } else if (!indented &&
                 parse_list_marker(first_nonspace_,
                                   blk(container).kind == BlockKind::Paragraph, data, width)) {
        advance_offset(first_nonspace_ + width - offset_, false);
        const bool saved_partial = partial_;
        const int saved_offset = offset_;
        const int saved_column = column_;
        while (column_ - saved_column <= 5 && !at_end(offset_) &&
               is_space_or_tab(static_cast<unsigned char>(at(offset_)))) {
          advance_offset(1, true);
        }
        const int i = column_ - saved_column;
        int padding;
        if (i >= 5 || i < 1 || at_end(offset_)) {
          padding = width + 1;
          offset_ = saved_offset;
          column_ = saved_column;
          partial_ = saved_partial;
          if (i > 0) advance_offset(1, true);
        } else {
          padding = width + i;
        }
        const int marker_offset = indent_;

        bool new_list = true;
        if (blk(container).kind == BlockKind::List) {
          const Block& l = blk(container);
          new_list = !(l.ordered == data.ordered && l.delimiter_or_bullet == data.delimiter_or_bullet);
        }
        if (new_list) {
          container = add_child(container, BlockKind::List);
          Block& l = blk(container);
          l.ordered = data.ordered;
          l.delimiter_or_bullet = data.delimiter_or_bullet;
          l.start = data.start;
        }
        container = add_child(container, BlockKind::Item);
        Block& item = blk(container);
        item.marker_offset = marker_offset;
        item.padding = padding;
      } else if (indented && !maybe_lazy && !blank_) {
        advance_offset(4, true);
        container = add_child(container, BlockKind::CodeBlock);
      } else {
        break;
      }

      if (accepts_lines(blk(container).kind)) break;
      maybe_lazy = false;
    }
  }

  // ---- Step 3: adding text -------------------------------------------------

  void add_line(int idx) {
    Block& b = blk(idx);
    if (partial_) {
      ++offset_;
      const int chars_to_tab = 4 - (column_ % 4);
      b.content.append(static_cast<std::size_t>(chars_to_tab), ' ');
    }
    if (offset_ < static_cast<int>(line_.size())) {
      b.content.append(line_.substr(static_cast<std::size_t>(offset_)));
    }
    b.content.push_back('\n');
  }

  /// Truncates the line so that an ATX heading's closing `#` sequence is
  /// excluded (cmark's `chop_trailing_hashtags`, applied to the whole line).
  void chop_trailing_hashtags() {
    std::size_t n = line_.size();
    while (n > 0 && is_space_char(static_cast<unsigned char>(line_[n - 1]))) --n;
    line_ = line_.substr(0, n);
    std::ptrdiff_t k = static_cast<std::ptrdiff_t>(n) - 1;
    while (k >= 0 && line_[static_cast<std::size_t>(k)] == '#') --k;
    if (k != static_cast<std::ptrdiff_t>(n) - 1 && k >= 0 &&
        is_space_or_tab(static_cast<unsigned char>(line_[static_cast<std::size_t>(k)]))) {
      std::size_t m = static_cast<std::size_t>(k);
      while (m > 0 && is_space_char(static_cast<unsigned char>(line_[m - 1]))) --m;
      line_ = line_.substr(0, m);
    }
  }

  void add_text_to_container(int container, int last_matched) {
    find_first_nonspace();
    Block& cont = blk(container);
    if (blank_ && cont.last_child >= 0) blk(cont.last_child).last_line_blank = true;

    const BlockKind ck = cont.kind;
    const bool llb = blank_ && ck != BlockKind::BlockQuote && ck != BlockKind::Heading &&
                     ck != BlockKind::ThematicBreak && !(ck == BlockKind::CodeBlock && cont.fenced) &&
                     !(ck == BlockKind::Item && cont.first_child < 0 && cont.start_line == line_no_);
    cont.last_line_blank = llb;
    for (int t = cont.parent; t >= 0; t = blk(t).parent) blk(t).last_line_blank = false;

    if (current_ != last_matched && container == last_matched && !blank_ &&
        blk(current_).kind == BlockKind::Paragraph) {
      // Lazy continuation line.
      add_line(current_);
      return;
    }
    while (current_ != last_matched) current_ = finalize(current_);

    if (ck == BlockKind::CodeBlock) {
      add_line(container);
    } else if (blank_) {
      // nothing
    } else if (ck == BlockKind::Heading || ck == BlockKind::Paragraph) {
      if (ck == BlockKind::Heading && !cont.setext) chop_trailing_hashtags();
      advance_offset(first_nonspace_ - offset_, false);
      add_line(container);
    } else {
      container = add_child(container, BlockKind::Paragraph);
      advance_offset(first_nonspace_ - offset_, false);
      add_line(container);
    }
    current_ = container;
  }

  void process_line(std::string_view line) {
    line_ = line;
    offset_ = 0;
    column_ = 0;
    partial_ = false;
    ++line_no_;

    int container = 0;
    bool all_matched = true;
    for (;;) {
      const int child = blk(container).last_child;
      if (child < 0 || !blk(child).open) break;
      container = child;
      find_first_nonspace();
      bool ok = true;
      switch (blk(container).kind) {
        case BlockKind::BlockQuote:
          ok = parse_block_quote_prefix();
          break;
        case BlockKind::Item:
          ok = parse_item_prefix(blk(container));
          break;
        case BlockKind::CodeBlock: {
          bool keep_going = true;
          ok = parse_code_block_prefix(container, keep_going);
          if (!keep_going) return;
          break;
        }
        case BlockKind::Heading:
          ok = false;
          break;
        case BlockKind::Paragraph:
          ok = !blank_;
          break;
        default:
          break;  // lists and thematic breaks always continue
      }
      if (!ok) {
        container = blk(container).parent;
        all_matched = false;
        break;
      }
    }

    const int last_matched = container;
    open_new_blocks(container, all_matched);
    add_text_to_container(container, last_matched);
  }

  std::vector<Block>& b_;
  std::string_view line_;
  int offset_ = 0;
  int column_ = 0;
  bool partial_ = false;
  int first_nonspace_ = 0;
  int first_nonspace_column_ = 0;
  int indent_ = 0;
  bool blank_ = false;
  int current_ = 0;
  int line_no_ = 0;
};

}  // namespace

void parse_blocks(std::string_view src, std::vector<Block>& blocks) {
  BlockParser parser(blocks);
  parser.run(src);
}

}  // namespace sitegen::md_detail
