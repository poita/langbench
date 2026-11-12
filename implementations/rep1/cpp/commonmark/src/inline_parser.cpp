// Phase 2: inline structure.
//
// Parses the raw text of a paragraph or heading left to right into inline
// nodes, using a delimiter stack for emphasis, a bracket stack for links and
// images, and a memo for code-span searches. Everything is iterative and every
// scanner costs what it examines; process-emphasis uses `openers_bottom`
// bounds so a block is parsed in linear time.
#include <array>
#include <cstddef>
#include <string>
#include <vector>

#include "internal.h"
#include "text_util.h"

namespace commonmark::detail {
namespace {

constexpr std::size_t npos = std::string::npos;

/// Characters that end a plain-text run.
constexpr std::array<bool, 256> make_special_table() {
  std::array<bool, 256> t{};
  for (char c : {'\n', '`', '\\', '&', '<', '*', '_', '[', ']', '!'}) {
    t[static_cast<unsigned char>(c)] = true;
  }
  return t;
}
constexpr std::array<bool, 256> kSpecial = make_special_table();

class InlineParser {
 public:
  explicit InlineParser(Document& doc) : doc_(doc) {}

  void parse(NodeId block) {
    // Take the raw text; trailing whitespace of the whole content is dropped.
    std::string raw = std::move(doc_[block].literal);
    doc_[block].literal.clear();
    s_.assign(rtrim(raw));
    pos_ = 0;
    parent_ = block;
    delims_.clear();
    top_ = -1;
    brackets_.clear();
    link_closed_ = true;
    if (backtick_memo_used_) {
      std::fill(backtick_last_.begin(), backtick_last_.end(), std::size_t{0});
      backtick_memo_used_ = false;
    }
    backticks_scanned_ = false;

    const std::size_t n = s_.size();
    while (pos_ < n) {
      switch (s_[pos_]) {
        case '\n': handle_newline(); break;
        case '`': handle_backticks(); break;
        case '\\': handle_backslash(); break;
        case '&': handle_entity(); break;
        case '<': handle_lt(); break;
        case '*':
        case '_': handle_delim_run(); break;
        case '[': handle_open_bracket(false); break;
        case '!':
          if (pos_ + 1 < n && s_[pos_ + 1] == '[') {
            handle_open_bracket(true);
          } else {
            add_text("!");
            ++pos_;
          }
          break;
        case ']': handle_close_bracket(); break;
        default: handle_text(); break;
      }
    }
    process_emphasis(0);
  }

 private:
  struct Delim {
    char ch;
    bool can_open;
    bool can_close;
    int orig_len;
    NodeId node;
    std::size_t position;
    int prev;
    int next;
  };
  struct Bracket {
    bool image;
    NodeId node;
    std::size_t position;
  };

  // ---- node helpers ---------------------------------------------------------

  NodeId add_node(NodeType t) {
    const NodeId id = doc_.create(t);
    doc_.append_child(parent_, id);
    return id;
  }

  NodeId add_text(std::string_view text) {
    const NodeId id = add_node(NodeType::Text);
    doc_[id].literal.assign(text);
    return id;
  }

  // ---- simple constructs ----------------------------------------------------

  void handle_text() {
    const std::size_t n = s_.size();
    const std::size_t start = pos_;
    std::size_t end = pos_ + 1;
    while (end < n && !kSpecial[static_cast<unsigned char>(s_[end])]) ++end;
    pos_ = end;
    if (end < n && s_[end] == '\n') {
      while (end > start && is_space(s_[end - 1])) --end;
    }
    if (end > start) add_text(std::string_view(s_).substr(start, end - start));
  }

  void handle_newline() {
    const bool hard = pos_ >= 2 && s_[pos_ - 1] == ' ' && s_[pos_ - 2] == ' ';
    add_node(hard ? NodeType::LineBreak : NodeType::SoftBreak);
    ++pos_;
    while (pos_ < s_.size() && is_space_or_tab(s_[pos_])) ++pos_;
  }

  void handle_backslash() {
    const std::size_t n = s_.size();
    if (pos_ + 1 < n && is_ascii_punct(s_[pos_ + 1])) {
      add_text(std::string_view(s_).substr(pos_ + 1, 1));
      pos_ += 2;
    } else if (pos_ + 1 < n && s_[pos_ + 1] == '\n') {
      add_node(NodeType::LineBreak);
      pos_ += 2;
    } else {
      add_text("\\");
      ++pos_;
    }
  }

  void handle_entity() {
    std::string decoded;
    const std::size_t used = match_entity(s_, pos_, decoded);
    if (used == 0) {
      add_text("&");
      ++pos_;
    } else {
      add_text(decoded);
      pos_ += used;
    }
  }

  // ---- code spans ------------------------------------------------------------

  std::size_t& backtick_last(std::size_t k) {
    if (k >= backtick_last_.size()) backtick_last_.resize(k + 1, 0);
    return backtick_last_[k];
  }

  /// Finds the start of the next backtick run of exactly `n` backticks at or
  /// after `from`, using cmark's memo (which can report "not found" early).
  std::size_t find_closing_backticks(std::size_t n, std::size_t from) {
    if (backticks_scanned_ && backtick_last(n) <= from) return npos;
    std::size_t i = from;
    for (;;) {
      i = s_.find('`', i);
      if (i == npos) break;
      std::size_t j = i;
      while (j < s_.size() && s_[j] == '`') ++j;
      const std::size_t k = j - i;
      backtick_last(k) = i;
      backtick_memo_used_ = true;
      if (k == n) return i;
      i = j;
    }
    backticks_scanned_ = true;
    return npos;
  }

  void handle_backticks() {
    const std::size_t start = pos_;
    while (pos_ < s_.size() && s_[pos_] == '`') ++pos_;
    const std::size_t n = pos_ - start;
    const std::size_t after_open = pos_;
    const std::size_t close = find_closing_backticks(n, after_open);
    if (close == npos) {
      add_text(std::string_view(s_).substr(start, n));
      return;
    }
    std::string code = s_.substr(after_open, close - after_open);
    for (char& c : code) {
      if (c == '\n') c = ' ';
    }
    if (code.size() >= 2 && code.front() == ' ' && code.back() == ' ' &&
        code.find_first_not_of(' ') != npos) {
      code = code.substr(1, code.size() - 2);
    }
    const NodeId id = add_node(NodeType::Code);
    doc_[id].literal = std::move(code);
    pos_ = close + n;
  }

  // ---- autolinks -------------------------------------------------------------

  /// With `i` just after '<': returns the index of the closing '>' of a URI
  /// or email autolink, or npos. Sets `email`.
  std::size_t scan_autolink(std::size_t i, bool& email) const {
    const std::size_t n = s_.size();
    // URI: scheme ':' [^\x00-\x20<>]* '>'
    if (i < n && is_alpha(s_[i])) {
      std::size_t j = i + 1;
      while (j < n && j - i < 32 && (is_alnum(s_[j]) || s_[j] == '.' || s_[j] == '+' || s_[j] == '-')) ++j;
      if (j - i >= 2 && j < n && s_[j] == ':') {
        ++j;
        while (j < n && static_cast<unsigned char>(s_[j]) > 0x20 && s_[j] != '<' && s_[j] != '>') ++j;
        if (j < n && s_[j] == '>') {
          email = false;
          return j;
        }
      }
    }
    // Email: local '@' domain
    static const std::string_view kLocalExtra = ".!#$%&'*+/=?^_`{|}~-";
    std::size_t j = i;
    while (j < n && (is_alnum(s_[j]) || kLocalExtra.find(s_[j]) != std::string_view::npos)) ++j;
    if (j == i || j >= n || s_[j] != '@') return npos;
    ++j;
    for (;;) {
      const std::size_t label_start = j;
      while (j < n && (is_alnum(s_[j]) || s_[j] == '-')) ++j;
      const std::size_t len = j - label_start;
      if (len == 0 || len > 63 || !is_alnum(s_[label_start]) || !is_alnum(s_[j - 1])) return npos;
      if (j < n && s_[j] == '.') {
        ++j;
        continue;
      }
      if (j < n && s_[j] == '>') {
        email = true;
        return j;
      }
      return npos;
    }
  }

  void handle_lt() {
    bool email = false;
    const std::size_t close = scan_autolink(pos_ + 1, email);
    if (close == npos) {
      add_text("<");
      ++pos_;
      return;
    }
    const std::string text = decode_entities(std::string_view(s_).substr(pos_ + 1, close - pos_ - 1));
    const NodeId link = add_node(NodeType::Link);
    doc_[link].literal = email ? "mailto:" + text : text;
    const NodeId child = doc_.create(NodeType::Text);
    doc_[child].literal = text;
    doc_.append_child(link, child);
    pos_ = close + 1;
  }

  // ---- emphasis delimiters -------------------------------------------------

  void handle_delim_run() {
    const char c = s_[pos_];
    const std::size_t start = pos_;
    while (pos_ < s_.size() && s_[pos_] == c) ++pos_;
    const std::size_t len = pos_ - start;
    const char before = start == 0 ? '\n' : s_[start - 1];
    const char after = pos_ >= s_.size() ? '\n' : s_[pos_];
    const bool ws_before = is_space(before), ws_after = is_space(after);
    const bool p_before = is_ascii_punct(before), p_after = is_ascii_punct(after);
    const bool left = !ws_after && (!p_after || ws_before || p_before);
    const bool right = !ws_before && (!p_before || ws_after || p_after);
    bool can_open, can_close;
    if (c == '*') {
      can_open = left;
      can_close = right;
    } else {
      can_open = left && (!right || p_before);
      can_close = right && (!left || p_after);
    }
    const NodeId id = add_node(NodeType::Text);
    doc_[id].literal.assign(len, c);
    if (can_open || can_close) {
      delims_.push_back(Delim{c, can_open, can_close, static_cast<int>(len), id, pos_, top_, -1});
      const int idx = static_cast<int>(delims_.size()) - 1;
      if (top_ >= 0) delims_[static_cast<std::size_t>(top_)].next = idx;
      top_ = idx;
    }
  }

  Delim& delim(int i) { return delims_[static_cast<std::size_t>(i)]; }

  /// Unlinks one entry from the delimiter stack.
  void remove_delim(int i) {
    Delim& d = delim(i);
    if (d.prev >= 0) delim(d.prev).next = d.next;
    if (d.next >= 0) {
      delim(d.next).prev = d.prev;
    } else {
      top_ = d.prev;
    }
  }

  void process_emphasis(std::size_t stack_bottom) {
    // The first entry at or after the bottom.
    int first = -1;
    for (int i = top_; i >= 0 && delim(i).position >= stack_bottom; i = delim(i).prev) first = i;

    std::array<std::size_t, 12> openers_bottom;
    openers_bottom.fill(stack_bottom);

    int closer = first;
    while (closer >= 0) {
      Delim& c = delim(closer);
      if (!c.can_close) {
        closer = c.next;
        continue;
      }
      const std::size_t kind = (c.ch == '*' ? 0u : 6u) + (c.can_open ? 3u : 0u) +
                               static_cast<std::size_t>(c.orig_len % 3);
      int opener = c.prev;
      bool found = false;
      while (opener >= 0 && delim(opener).position >= openers_bottom[kind]) {
        const Delim& o = delim(opener);
        if (o.can_open && o.ch == c.ch &&
            (!(c.can_open || o.can_close) || c.orig_len % 3 == 0 ||
             (o.orig_len + c.orig_len) % 3 != 0)) {
          found = true;
          break;
        }
        opener = o.prev;
      }
      if (!found) {
        openers_bottom[kind] = c.position;
        const int next = c.next;
        if (!c.can_open) remove_delim(closer);
        closer = next;
        continue;
      }

      Delim& o = delim(opener);
      const NodeId open_node = o.node, close_node = c.node;
      std::string& open_text = doc_[open_node].literal;
      std::string& close_text = doc_[close_node].literal;
      const std::size_t use = (open_text.size() >= 2 && close_text.size() >= 2) ? 2 : 1;
      open_text.resize(open_text.size() - use);
      close_text.resize(close_text.size() - use);

      // Drop every entry strictly between opener and closer.
      o.next = closer;
      c.prev = opener;

      // Wrap everything between the two text nodes.
      const NodeId wrapper = doc_.create(use == 2 ? NodeType::Strong : NodeType::Emph);
      doc_.insert_after(open_node, wrapper);
      const NodeId first_inside = doc_[wrapper].next;
      if (first_inside != close_node) {
        doc_.move_run(first_inside, doc_[close_node].prev, wrapper);
      }

      const bool open_empty = doc_[open_node].literal.empty();
      const bool close_empty = doc_[close_node].literal.empty();
      const int next = delim(closer).next;
      if (open_empty) {
        doc_.unlink(open_node);
        remove_delim(opener);
      }
      if (close_empty) {
        doc_.unlink(close_node);
        remove_delim(closer);
        closer = next;
      }
    }

    // Remove all entries at or after the bottom.
    while (top_ >= 0 && delim(top_).position >= stack_bottom) top_ = delim(top_).prev;
    if (top_ >= 0) delim(top_).next = -1;
  }

  // ---- brackets, links and images -------------------------------------------

  void handle_open_bracket(bool image) {
    const NodeId id = add_text(image ? "![" : "[");
    pos_ += image ? 2 : 1;
    brackets_.push_back(Bracket{image, id, pos_});
    if (!image) link_closed_ = false;
  }

  std::size_t skip_ws(std::size_t i) const {
    while (i < s_.size() && is_space(s_[i])) ++i;
    return i;
  }

  /// Longest title match starting at the opening delimiter `s_[i]`; returns
  /// the index just after the closing delimiter, or npos.
  std::size_t scan_title(std::size_t i) const {
    const char open = s_[i];
    if (open != '"' && open != '\'' && open != '(') return npos;
    const char close = open == '(' ? ')' : open;
    std::size_t last_end = npos;
    for (std::size_t j = i + 1; j < s_.size(); ++j) {
      const char c = s_[j];
      if (c == close) {
        last_end = j + 1;
        if (s_[j - 1] != '\\') break;
      } else if (open == '(' && c == '(') {
        if (s_[j - 1] != '\\') break;
      }
    }
    return last_end;
  }

  /// Parses `(dest "title")` with `i` just after the `]`.
  bool parse_link_tail(std::size_t i, std::string& dest, std::string& title, bool& has_title,
                       std::size_t& end) const {
    const std::size_t n = s_.size();
    if (i >= n || s_[i] != '(') return false;
    i = skip_ws(i + 1);

    std::size_t dest_begin, dest_end, after_dest;
    if (i < n && s_[i] == '<') {
      std::size_t j = i + 1;
      bool closed = false;
      while (j < n) {
        const char c = s_[j];
        if (c == '>') {
          ++j;
          closed = true;
          break;
        }
        if (c == '\\') {
          j += 2;
        } else if (c == '\n' || c == '<') {
          return false;
        } else {
          ++j;
        }
      }
      if (!closed || j >= n) return false;
      dest_begin = i + 1;
      dest_end = j - 1;
      after_dest = j;
    } else {
      std::size_t j = i;
      int nesting = 0;
      while (j < n) {
        const char c = s_[j];
        if (c == '\\' && j + 1 < n && is_ascii_punct(s_[j + 1])) {
          j += 2;
        } else if (c == '(') {
          ++nesting;
          ++j;
          if (nesting > 32) return false;
        } else if (c == ')') {
          if (nesting == 0) break;
          --nesting;
          ++j;
        } else if (is_space(c)) {
          break;
        } else {
          ++j;
        }
      }
      if (j >= n || nesting != 0) return false;
      dest_begin = i;
      dest_end = j;
      after_dest = j;
    }

    std::size_t k = skip_ws(after_dest);
    has_title = false;
    std::string raw_title;
    if (k != after_dest) {
      const std::size_t title_end = scan_title(k);
      if (title_end != npos) {
        has_title = true;
        raw_title = s_.substr(k + 1, title_end - k - 2);
        k = title_end;
      }
    }
    k = skip_ws(k);
    if (k >= n || s_[k] != ')') return false;

    dest = unescape_backslashes(
        decode_entities(trim(std::string_view(s_).substr(dest_begin, dest_end - dest_begin))));
    title = has_title ? unescape_backslashes(decode_entities(raw_title)) : std::string();
    end = k + 1;
    return true;
  }

  void handle_close_bracket() {
    const std::size_t close_pos = pos_;
    ++pos_;
    if (brackets_.empty()) {
      add_text("]");
      return;
    }
    const Bracket opener = brackets_.back();
    if (!opener.image && link_closed_) {
      brackets_.pop_back();
      add_text("]");
      return;
    }

    std::string dest, title;
    bool has_title = false;
    std::size_t end = 0;
    if (!parse_link_tail(close_pos + 1, dest, title, has_title, end)) {
      brackets_.pop_back();
      add_text("]");
      return;
    }

    // Build the link/image around everything after the opener's text node.
    const NodeId link = doc_.create(opener.image ? NodeType::Image : NodeType::Link);
    {
      Node& l = doc_[link];
      l.literal = std::move(dest);
      l.extra = std::move(title);
      l.has_title = has_title;
    }
    const NodeId first_inside = doc_[opener.node].next;
    const NodeId last_inside = doc_[parent_].last_child;
    doc_.unlink(opener.node);
    doc_.append_child(parent_, link);
    if (first_inside != kNoNode) doc_.move_run(first_inside, last_inside, link);

    process_emphasis(opener.position);
    brackets_.pop_back();
    if (!opener.image) link_closed_ = true;
    pos_ = end;
  }

  Document& doc_;
  std::string s_;
  std::size_t pos_ = 0;
  NodeId parent_ = kNoNode;
  std::vector<Delim> delims_;
  int top_ = -1;
  std::vector<Bracket> brackets_;
  bool link_closed_ = true;
  std::vector<std::size_t> backtick_last_;
  bool backticks_scanned_ = false;
  bool backtick_memo_used_ = false;
};

}  // namespace

void parse_inlines(Document& doc) {
  InlineParser parser(doc);
  const std::size_t count = doc.size();
  for (std::size_t i = 0; i < count; ++i) {
    const NodeType t = doc[static_cast<NodeId>(i)].type;
    if (t == NodeType::Paragraph || t == NodeType::Heading) {
      parser.parse(static_cast<NodeId>(i));
    }
  }
}

}  // namespace commonmark::detail
