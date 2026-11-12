// HTML output: one iterative walk over the finished tree.
#include "commonmark/html.h"

#include <cctype>
#include <string_view>

#include "text_util.h"

namespace commonmark {
namespace {

using detail::is_space;

class HtmlWriter {
 public:
  explicit HtmlWriter(const Document& doc) : doc_(doc) {}

  std::string run() {
    NodeId cur = doc_.root();
    bool entering = true;
    for (;;) {
      const Node& n = doc_[cur];
      if (entering) {
        const bool descend = enter(cur, n);
        if (descend && n.first_child != kNoNode) {
          cur = n.first_child;
          continue;
        }
      }
      exit(cur, n);
      if (cur == doc_.root()) break;
      if (n.next != kNoNode) {
        cur = n.next;
        entering = true;
      } else {
        cur = n.parent;
        entering = false;
      }
    }
    return std::move(out_);
  }

 private:
  void cr() {
    if (!out_.empty() && out_.back() != '\n') out_.push_back('\n');
  }

  void escape_html(std::string_view s) {
    std::size_t run = 0;
    for (std::size_t i = 0; i < s.size(); ++i) {
      const char* rep = nullptr;
      switch (s[i]) {
        case '&': rep = "&amp;"; break;
        case '<': rep = "&lt;"; break;
        case '>': rep = "&gt;"; break;
        case '"': rep = "&quot;"; break;
        default: break;
      }
      if (rep != nullptr) {
        out_.append(s.substr(run, i - run));
        out_.append(rep);
        run = i + 1;
      }
    }
    out_.append(s.substr(run));
  }

  static bool starts_with_icase(std::string_view s, std::string_view prefix) {
    if (s.size() < prefix.size()) return false;
    for (std::size_t i = 0; i < prefix.size(); ++i) {
      if (std::tolower(static_cast<unsigned char>(s[i])) != prefix[i]) return false;
    }
    return true;
  }

  static bool is_safe_url(std::string_view url) {
    if (starts_with_icase(url, "javascript:") || starts_with_icase(url, "vbscript:") ||
        starts_with_icase(url, "file:")) {
      return false;
    }
    if (starts_with_icase(url, "data:")) {
      return starts_with_icase(url, "data:image/png") || starts_with_icase(url, "data:image/gif") ||
             starts_with_icase(url, "data:image/jpeg") || starts_with_icase(url, "data:image/webp");
    }
    return true;
  }

  void write_href(std::string_view url) {
    if (!is_safe_url(url)) return;
    static constexpr char kHex[] = "0123456789ABCDEF";
    static constexpr std::string_view kSafe =
        "-_.~!#$%()*+,/:;=?@";  // plus ASCII alphanumerics
    for (const char ch : url) {
      const unsigned char c = static_cast<unsigned char>(ch);
      if (detail::is_alnum(ch) || kSafe.find(ch) != std::string_view::npos) {
        out_.push_back(ch);
      } else if (ch == '&') {
        out_.append("&amp;");
      } else if (ch == '\'') {
        out_.append("&#x27;");
      } else {
        out_.push_back('%');
        out_.push_back(kHex[c >> 4]);
        out_.push_back(kHex[c & 15]);
      }
    }
  }

  /// Writes the plain text of the descendants of `root` (image alt text).
  void write_alt_text(NodeId root) {
    const Node& r = doc_[root];
    NodeId cur = r.first_child;
    if (cur == kNoNode) return;
    for (;;) {
      const Node& n = doc_[cur];
      switch (n.type) {
        case NodeType::Text:
        case NodeType::Code:
          escape_html(n.literal);
          break;
        case NodeType::SoftBreak:
        case NodeType::LineBreak:
          out_.push_back(' ');
          break;
        default:
          break;
      }
      if (n.first_child != kNoNode) {
        cur = n.first_child;
        continue;
      }
      while (cur != root && doc_[cur].next == kNoNode) cur = doc_[cur].parent;
      if (cur == root) return;
      cur = doc_[cur].next;
    }
  }

  bool in_tight_list(const Node& para) const {
    if (para.parent == kNoNode) return false;
    const Node& item = doc_[para.parent];
    if (item.parent == kNoNode) return false;
    const Node& list = doc_[item.parent];
    return list.type == NodeType::List && list.list_tight;
  }

  /// Emits the opening markup; returns whether to visit the children.
  bool enter(NodeId id, const Node& n) {
    switch (n.type) {
      case NodeType::Document:
        break;
      case NodeType::BlockQuote:
        cr();
        out_.append("<blockquote>\n");
        break;
      case NodeType::List:
        cr();
        if (n.list_type == ListType::Bullet) {
          out_.append("<ul>\n");
        } else if (n.list_start == 1) {
          out_.append("<ol>\n");
        } else {
          out_.append("<ol start=\"").append(std::to_string(n.list_start)).append("\">\n");
        }
        break;
      case NodeType::Item:
        cr();
        out_.append("<li>");
        break;
      case NodeType::Paragraph:
        if (!in_tight_list(n)) {
          cr();
          out_.append("<p>");
        }
        break;
      case NodeType::Heading:
        cr();
        out_.append("<h").push_back(static_cast<char>('0' + n.level));
        out_.push_back('>');
        break;
      case NodeType::ThematicBreak:
        cr();
        out_.append("<hr />\n");
        break;
      case NodeType::CodeBlock: {
        cr();
        out_.append("<pre><code");
        const std::string_view info = n.info();
        if (!info.empty()) {
          std::size_t end = 0;
          while (end < info.size() && !is_space(info[end])) ++end;
          std::string_view lang = info.substr(0, end);
          out_.append(" class=\"");
          if (lang.substr(0, 9) != "language-") out_.append("language-");
          escape_html(lang);
          out_.push_back('"');
        }
        out_.push_back('>');
        escape_html(n.literal);
        out_.append("</code></pre>\n");
        break;
      }
      case NodeType::Text:
        escape_html(n.literal);
        break;
      case NodeType::SoftBreak:
        out_.push_back('\n');
        break;
      case NodeType::LineBreak:
        out_.append("<br />\n");
        break;
      case NodeType::Code:
        out_.append("<code>");
        escape_html(n.literal);
        out_.append("</code>");
        break;
      case NodeType::Emph:
        out_.append("<em>");
        break;
      case NodeType::Strong:
        out_.append("<strong>");
        break;
      case NodeType::Link:
        out_.append("<a href=\"");
        write_href(n.destination());
        out_.push_back('"');
        if (n.has_title) {
          out_.append(" title=\"");
          escape_html(n.title());
          out_.push_back('"');
        }
        out_.push_back('>');
        break;
      case NodeType::Image:
        out_.append("<img src=\"");
        write_href(n.destination());
        out_.append("\" alt=\"");
        write_alt_text(id);
        out_.push_back('"');
        if (n.has_title) {
          out_.append(" title=\"");
          escape_html(n.title());
          out_.push_back('"');
        }
        out_.append(" />");
        return false;
    }
    return n.type != NodeType::ThematicBreak && n.type != NodeType::CodeBlock;
  }

  void exit(NodeId, const Node& n) {
    switch (n.type) {
      case NodeType::BlockQuote:
        cr();
        out_.append("</blockquote>\n");
        break;
      case NodeType::List:
        cr();
        out_.append(n.list_type == ListType::Bullet ? "</ul>\n" : "</ol>\n");
        break;
      case NodeType::Item:
        out_.append("</li>\n");
        break;
      case NodeType::Paragraph:
        if (!in_tight_list(n)) out_.append("</p>\n");
        break;
      case NodeType::Heading:
        out_.append("</h").push_back(static_cast<char>('0' + n.level));
        out_.append(">\n");
        break;
      case NodeType::Emph:
        out_.append("</em>");
        break;
      case NodeType::Strong:
        out_.append("</strong>");
        break;
      case NodeType::Link:
        out_.append("</a>");
        break;
      default:
        break;
    }
  }

  const Document& doc_;
  std::string out_;
};

}  // namespace

std::string render_html(const Document& doc) { return HtmlWriter(doc).run(); }

}  // namespace commonmark
