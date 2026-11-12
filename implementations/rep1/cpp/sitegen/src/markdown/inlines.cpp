// Phase 2 of the Markdown conversion: inline parsing.
//
// A left-to-right scanner with a delimiter stack for emphasis and a bracket
// stack for links and images, in the style of cmark's `inlines.c`. Inline
// nodes live in an arena and are linked with indices so that wrapping a range
// of siblings in a new node costs O(1) per node moved.
#include <algorithm>

#include "common.hpp"

namespace sitegen::md_detail {

namespace {

struct Delim {
  char ch = 0;
  int orig_len = 0;
  bool can_open = false;
  bool can_close = false;
  int node = -1;
  int position = 0;
  int prev = -1;
  int next = -1;
};

struct Bracket {
  bool image = false;
  int node = -1;
  int position = 0;
  int prev_delim = -1;
};

bool is_special(unsigned char c) {
  switch (c) {
    case '\n': case '`': case '\\': case '&': case '<': case '*': case '_': case '[': case ']':
    case '!':
      return true;
    default:
      return false;
  }
}

class InlineParser {
 public:
  InlineParser(std::string_view s, InlineTree& tree) : s_(s), t_(tree) {}

  void parse() {
    t_.nodes.clear();
    t_.nodes.emplace_back();
    t_.nodes[0].kind = InlineKind::Root;
    while (pos_ < s_.size()) parse_one();
    process_emphasis(0, -1, 0);
  }

 private:
  // ---- Node list helpers --------------------------------------------------

  Inline& node(int i) { return t_.nodes[static_cast<std::size_t>(i)]; }
  Delim& delim(int i) { return delims_[static_cast<std::size_t>(i)]; }

  int new_node(InlineKind kind) {
    t_.nodes.emplace_back();
    t_.nodes.back().kind = kind;
    return static_cast<int>(t_.nodes.size()) - 1;
  }

  void append(int container, int n) {
    Inline& c = node(container);
    node(n).prev = c.last;
    node(n).next = -1;
    if (c.last >= 0) node(c.last).next = n;
    else c.first = n;
    node(container).last = n;
  }

  void unlink(int container, int n) {
    const int p = node(n).prev, nx = node(n).next;
    if (p >= 0) node(p).next = nx;
    else node(container).first = nx;
    if (nx >= 0) node(nx).prev = p;
    else node(container).last = p;
    node(n).prev = node(n).next = -1;
  }

  void insert_after(int container, int after, int n) {
    const int nx = node(after).next;
    node(n).prev = after;
    node(n).next = nx;
    node(after).next = n;
    if (nx >= 0) node(nx).prev = n;
    else node(container).last = n;
  }

  int add_text(std::string_view text) {
    const int n = new_node(InlineKind::Text);
    node(n).text.assign(text);
    append(0, n);
    return n;
  }

  int add_simple(InlineKind kind) {
    const int n = new_node(kind);
    append(0, n);
    return n;
  }

  // ---- Delimiter stack ----------------------------------------------------

  int push_delim(const Delim& d) {
    delims_.push_back(d);
    const int i = static_cast<int>(delims_.size()) - 1;
    delim(i).prev = delim_tail_;
    delim(i).next = -1;
    if (delim_tail_ >= 0) delim(delim_tail_).next = i;
    else delim_head_ = i;
    delim_tail_ = i;
    return i;
  }

  void remove_delim(int i) {
    const int p = delim(i).prev, nx = delim(i).next;
    if (p >= 0) delim(p).next = nx;
    else delim_head_ = nx;
    if (nx >= 0) delim(nx).prev = p;
    else delim_tail_ = p;
  }

  /// Processes emphasis for the delimiter entries after `prev_delim` (the
  /// entry that was on top of the stack when the bracket was opened, or -1)
  /// with `stack_bottom` the corresponding position bound. The nodes live in
  /// the child list of `container`.
  void process_emphasis(int container, int prev_delim, int stack_bottom) {
    int openers_bottom[12];
    std::fill(openers_bottom, openers_bottom + 12, stack_bottom);
    int closer = prev_delim >= 0 ? delim(prev_delim).next : delim_head_;
    while (closer >= 0) {
      Delim& c = delim(closer);
      if (!c.can_close) {
        closer = c.next;
        continue;
      }
      const int kind = (c.ch == '_' ? 6 : 0) + (c.can_open ? 3 : 0) + c.orig_len % 3;
      int opener = c.prev;
      bool found = false;
      while (opener >= 0 && delim(opener).position >= openers_bottom[kind]) {
        const Delim& o = delim(opener);
        if (o.can_open && o.ch == c.ch) {
          const bool odd_match = (c.can_open || o.can_close) && c.orig_len % 3 != 0 &&
                                 (o.orig_len + c.orig_len) % 3 == 0;
          if (!odd_match) {
            found = true;
            break;
          }
        }
        opener = o.prev;
      }
      if (!found) {
        openers_bottom[kind] = c.position;
        const int nx = c.next;
        if (!c.can_open) remove_delim(closer);
        closer = nx;
        continue;
      }

      Inline& on = node(delim(opener).node);
      Inline& cn = node(c.node);
      const int use = (on.text.size() >= 2 && cn.text.size() >= 2) ? 2 : 1;
      on.text.erase(on.text.size() - static_cast<std::size_t>(use));
      cn.text.erase(0, static_cast<std::size_t>(use));

      for (int d = delim(opener).next; d != closer;) {
        const int nx = delim(d).next;
        remove_delim(d);
        d = nx;
      }

      // Wrap the nodes strictly between the two text nodes.
      const int o_node = delim(opener).node;
      const int c_node = c.node;
      const int wrap = new_node(use == 2 ? InlineKind::Strong : InlineKind::Emph);
      const int first = node(o_node).next;
      if (first != c_node) {
        const int last = node(c_node).prev;
        node(o_node).next = c_node;
        node(c_node).prev = o_node;
        node(first).prev = -1;
        node(last).next = -1;
        node(wrap).first = first;
        node(wrap).last = last;
      }
      insert_after(container, o_node, wrap);

      if (node(o_node).text.empty()) {
        unlink(container, o_node);
        remove_delim(opener);
      }
      if (node(c_node).text.empty()) {
        unlink(container, c_node);
        const int nx = delim(closer).next;
        remove_delim(closer);
        closer = nx;
      }
    }
    while (delim_tail_ != prev_delim) remove_delim(delim_tail_);
  }

  // ---- Scanners ------------------------------------------------------------

  void skip_spaces(std::size_t& i) const {
    while (i < s_.size() && is_space_char(static_cast<unsigned char>(s_[i]))) ++i;
  }

  /// If the backtick run of length `n` starting before `p` has a matching
  /// closing run, returns its start; otherwise npos. Uses cmark's memo.
  std::size_t find_closing_backticks(std::size_t p, std::size_t n) {
    if (n >= last_.size()) last_.resize(n + 1, 0);
    if (scanned_ && static_cast<std::size_t>(last_[n]) <= p) return std::string_view::npos;
    std::size_t i = p;
    while (i < s_.size()) {
      if (s_[i] != '`') {
        ++i;
        continue;
      }
      const std::size_t start = i;
      while (i < s_.size() && s_[i] == '`') ++i;
      const std::size_t k = i - start;
      if (k >= last_.size()) last_.resize(k + 1, 0);
      last_[k] = static_cast<int>(start);
      if (k == n) return start;
    }
    scanned_ = true;
    return std::string_view::npos;
  }

  /// Matches an autolink body starting right after `<`. Returns the index of
  /// the closing `>` or npos; `is_email` tells which form matched.
  std::size_t scan_autolink(std::size_t i, bool& is_email) const {
    const std::size_t n = s_.size();
    // URI autolink.
    if (i < n && is_alpha(static_cast<unsigned char>(s_[i]))) {
      std::size_t j = i + 1;
      while (j < n && (is_alnum(static_cast<unsigned char>(s_[j])) || s_[j] == '.' ||
                       s_[j] == '+' || s_[j] == '-')) {
        ++j;
      }
      const std::size_t scheme_rest = j - (i + 1);
      if (scheme_rest >= 1 && scheme_rest <= 31 && j < n && s_[j] == ':') {
        ++j;
        while (j < n) {
          const unsigned char c = static_cast<unsigned char>(s_[j]);
          if (c <= 0x20 || c == '<' || c == '>') break;
          ++j;
        }
        if (j < n && s_[j] == '>') {
          is_email = false;
          return j;
        }
      }
    }
    // Email autolink.
    static const std::string_view kLocal = "!#$%&'*+/=?^_`{|}~-.";
    std::size_t j = i;
    while (j < n && (is_alnum(static_cast<unsigned char>(s_[j])) ||
                     kLocal.find(s_[j]) != std::string_view::npos)) {
      ++j;
    }
    if (j == i || j >= n || s_[j] != '@') return std::string_view::npos;
    ++j;
    for (;;) {
      const std::size_t label_start = j;
      while (j < n && (is_alnum(static_cast<unsigned char>(s_[j])) || s_[j] == '-')) ++j;
      const std::size_t len = j - label_start;
      if (len == 0 || len > 63 || s_[label_start] == '-' || s_[j - 1] == '-') {
        return std::string_view::npos;
      }
      if (j < n && s_[j] == '.') {
        ++j;
        continue;
      }
      break;
    }
    if (j < n && s_[j] == '>') {
      is_email = true;
      return j;
    }
    return std::string_view::npos;
  }

  /// Scans a link title starting at `i` (a quote or parenthesis). Returns the
  /// index just past the longest valid title, or `i` when there is none.
  std::size_t scan_title(std::size_t i) const {
    const char open = s_[i];
    const char close = open == '(' ? ')' : open;
    const std::size_t n = s_.size();
    // reach[0], reach[1], reach[2]: is position j, j+1, j+2 reachable?
    bool r0 = true, r1 = false, r2 = false;
    std::size_t best = i;
    for (std::size_t j = i + 1; j <= n && (r0 || r1 || r2); ++j) {
      if (r0 && j < n) {
        const char c = s_[j];
        if (c == close) {
          best = j + 1;
        } else if (c != '\0' && !(open == '(' && c == '(')) {
          r1 = true;
        }
        if (c == '\\' && j + 1 < n && is_ascii_punct(static_cast<unsigned char>(s_[j + 1]))) {
          r2 = true;
        }
      }
      r0 = r1;
      r1 = r2;
      r2 = false;
    }
    return best;
  }

  // ---- Inline constructs ---------------------------------------------------

  void parse_newline() {
    const bool hard = pos_ >= 2 && s_[pos_ - 1] == ' ' && s_[pos_ - 2] == ' ';
    ++pos_;
    while (pos_ < s_.size() && is_space_or_tab(static_cast<unsigned char>(s_[pos_]))) ++pos_;
    add_simple(hard ? InlineKind::LineBreak : InlineKind::SoftBreak);
  }

  void parse_backticks() {
    std::size_t p = pos_;
    while (p < s_.size() && s_[p] == '`') ++p;
    const std::size_t n = p - pos_;
    const std::size_t close = find_closing_backticks(p, n);
    if (close == std::string_view::npos) {
      add_text(s_.substr(pos_, n));
      pos_ = p;
      return;
    }
    std::string content(s_.substr(p, close - p));
    std::replace(content.begin(), content.end(), '\n', ' ');
    if (content.size() >= 2 && content.front() == ' ' && content.back() == ' ' &&
        content.find_first_not_of(' ') != std::string::npos) {
      content = content.substr(1, content.size() - 2);
    }
    const int c = add_simple(InlineKind::Code);
    node(c).text = std::move(content);
    pos_ = close + n;
  }

  void parse_backslash() {
    if (pos_ + 1 < s_.size()) {
      const char n = s_[pos_ + 1];
      if (is_ascii_punct(static_cast<unsigned char>(n))) {
        add_text(s_.substr(pos_ + 1, 1));
        pos_ += 2;
        return;
      }
      if (n == '\n') {
        add_simple(InlineKind::LineBreak);
        pos_ += 2;
        return;
      }
    }
    add_text("\\");
    ++pos_;
  }

  void parse_entity() {
    std::string decoded;
    const std::size_t used = decode_entity_at(s_, pos_ + 1, decoded);
    if (used == 0) {
      add_text("&");
      ++pos_;
      return;
    }
    add_text(decoded);
    pos_ += 1 + used;
  }

  void parse_lt() {
    bool is_email = false;
    const std::size_t close = scan_autolink(pos_ + 1, is_email);
    if (close == std::string_view::npos) {
      add_text("<");
      ++pos_;
      return;
    }
    const std::string text = decode_entities(s_.substr(pos_ + 1, close - pos_ - 1));
    const int link = add_simple(InlineKind::Link);
    node(link).dest = (is_email ? "mailto:" : "") + text;
    const int child = new_node(InlineKind::Text);
    node(child).text = text;
    append(link, child);
    pos_ = close + 1;
  }

  void parse_delimiter_run() {
    const char ch = s_[pos_];
    std::size_t end = pos_;
    while (end < s_.size() && s_[end] == ch) ++end;
    const char before = pos_ == 0 ? '\n' : s_[pos_ - 1];
    const char after = end >= s_.size() ? '\n' : s_[end];
    const bool before_space = is_space_char(static_cast<unsigned char>(before));
    const bool after_space = is_space_char(static_cast<unsigned char>(after));
    const bool before_punct = is_ascii_punct(static_cast<unsigned char>(before));
    const bool after_punct = is_ascii_punct(static_cast<unsigned char>(after));
    const bool left = !after_space && (!after_punct || before_space || before_punct);
    const bool right = !before_space && (!before_punct || after_space || after_punct);
    bool can_open, can_close;
    if (ch == '*') {
      can_open = left;
      can_close = right;
    } else {
      can_open = left && (!right || before_punct);
      can_close = right && (!left || after_punct);
    }
    const int n = add_text(s_.substr(pos_, end - pos_));
    if (can_open || can_close) {
      Delim d;
      d.ch = ch;
      d.orig_len = static_cast<int>(end - pos_);
      d.can_open = can_open;
      d.can_close = can_close;
      d.node = n;
      d.position = static_cast<int>(end);
      push_delim(d);
    }
    pos_ = end;
  }

  void parse_open_bracket(bool image) {
    const int n = add_text(image ? "![" : "[");
    pos_ += image ? 2 : 1;
    Bracket b;
    b.image = image;
    b.node = n;
    b.position = static_cast<int>(pos_);
    b.prev_delim = delim_tail_;
    brackets_.push_back(b);
    if (!image) link_closed_ = false;
  }

  struct LinkTail {
    std::string dest;
    std::string title;
    bool has_title = false;
    std::size_t end = 0;  // index just past the closing parenthesis
  };

  bool parse_inline_link_tail(std::size_t i, LinkTail& out) const {
    const std::size_t n = s_.size();
    if (i >= n || s_[i] != '(') return false;
    ++i;
    skip_spaces(i);
    std::string_view raw_dest;
    if (i < n && s_[i] == '<') {
      std::size_t j = i + 1;
      while (j < n) {
        if (s_[j] == '>') {
          ++j;
          break;
        }
        if (s_[j] == '\\') j += 2;
        else if (s_[j] == '\n' || s_[j] == '<') return false;
        else ++j;
      }
      if (j >= n) return false;
      raw_dest = s_.substr(i + 1, j - i - 2);
      i = j;
    } else {
      std::size_t j = i;
      int nesting = 0;
      while (j < n) {
        const char c = s_[j];
        if (c == '\\' && j + 1 < n && is_ascii_punct(static_cast<unsigned char>(s_[j + 1]))) {
          j += 2;
        } else if (c == '(') {
          ++nesting;
          ++j;
          if (nesting > 32) return false;
        } else if (c == ')') {
          if (nesting == 0) break;
          --nesting;
          ++j;
        } else if (is_space_char(static_cast<unsigned char>(c))) {
          break;
        } else {
          ++j;
        }
      }
      if (j >= n || nesting != 0) return false;
      raw_dest = s_.substr(i, j - i);
      i = j;
    }
    std::size_t k = i;
    skip_spaces(k);
    std::size_t title_end = k;
    if (k > i && k < n && (s_[k] == '"' || s_[k] == '\'' || s_[k] == '(')) {
      title_end = scan_title(k);
      if (title_end > k) {
        out.has_title = true;
        out.title = unescape_backslashes(
            decode_entities(s_.substr(k + 1, title_end - k - 2)));
      }
    }
    k = title_end;
    skip_spaces(k);
    if (k >= n || s_[k] != ')') return false;
    std::size_t ds = 0, de = raw_dest.size();
    while (ds < de && is_space_char(static_cast<unsigned char>(raw_dest[ds]))) ++ds;
    while (de > ds && is_space_char(static_cast<unsigned char>(raw_dest[de - 1]))) --de;
    out.dest = unescape_backslashes(decode_entities(raw_dest.substr(ds, de - ds)));
    out.end = k + 1;
    return true;
  }

  void parse_close_bracket() {
    const std::size_t after = pos_ + 1;
    if (brackets_.empty()) {
      add_text("]");
      pos_ = after;
      return;
    }
    const Bracket opener = brackets_.back();
    if (!opener.image && link_closed_) {
      brackets_.pop_back();
      add_text("]");
      pos_ = after;
      return;
    }
    LinkTail tail;
    if (!parse_inline_link_tail(after, tail)) {
      brackets_.pop_back();
      add_text("]");
      pos_ = after;
      return;
    }

    const int link = new_node(opener.image ? InlineKind::Image : InlineKind::Link);
    node(link).dest = std::move(tail.dest);
    node(link).title = std::move(tail.title);
    node(link).has_title = tail.has_title;
    // Move every node after the opener's text node into the new node.
    const int first = node(opener.node).next;
    if (first >= 0) {
      const int last = node(0).last;
      node(opener.node).next = -1;
      node(0).last = opener.node;
      node(first).prev = -1;
      node(link).first = first;
      node(link).last = last;
    }
    unlink(0, opener.node);
    append(0, link);
    process_emphasis(link, opener.prev_delim, opener.position);
    brackets_.pop_back();
    if (!opener.image) link_closed_ = true;
    pos_ = tail.end;
  }

  void parse_text_run() {
    std::size_t end = pos_;
    while (end < s_.size() && !is_special(static_cast<unsigned char>(s_[end]))) ++end;
    std::size_t stop = end;
    if (end < s_.size() && s_[end] == '\n') {
      while (stop > pos_ && is_space_or_tab(static_cast<unsigned char>(s_[stop - 1]))) --stop;
    }
    if (stop > pos_) add_text(s_.substr(pos_, stop - pos_));
    pos_ = end;
  }

  void parse_one() {
    switch (s_[pos_]) {
      case '\n': parse_newline(); break;
      case '`': parse_backticks(); break;
      case '\\': parse_backslash(); break;
      case '&': parse_entity(); break;
      case '<': parse_lt(); break;
      case '*':
      case '_': parse_delimiter_run(); break;
      case '[': parse_open_bracket(false); break;
      case ']': parse_close_bracket(); break;
      case '!':
        if (pos_ + 1 < s_.size() && s_[pos_ + 1] == '[') {
          parse_open_bracket(true);
        } else {
          add_text("!");
          ++pos_;
        }
        break;
      default: parse_text_run(); break;
    }
  }

  std::string_view s_;
  InlineTree& t_;
  std::size_t pos_ = 0;
  std::vector<Delim> delims_;
  int delim_head_ = -1;
  int delim_tail_ = -1;
  std::vector<Bracket> brackets_;
  bool link_closed_ = true;
  std::vector<int> last_;
  bool scanned_ = false;
};

}  // namespace

void parse_inlines(std::string_view content, InlineTree& tree) {
  std::size_t n = content.size();
  while (n > 0 && is_space_char(static_cast<unsigned char>(content[n - 1]))) --n;
  InlineParser parser(content.substr(0, n), tree);
  parser.parse();
}

}  // namespace sitegen::md_detail
