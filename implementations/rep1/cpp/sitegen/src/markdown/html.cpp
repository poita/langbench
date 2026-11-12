// HTML rendering of the inline tree and the block tree, and the public entry
// point `markdown_to_html`.
#include "sitegen/markdown.hpp"

#include "common.hpp"

namespace sitegen {

namespace md_detail {

namespace {

void render_alt_text(const InlineTree& tree, int image, std::string& out) {
  // Plain text of the image's descendants.
  auto node = [&](int i) -> const Inline& { return tree.nodes[static_cast<std::size_t>(i)]; };
  std::vector<int> stack;
  int cur = node(image).first;
  while (true) {
    if (cur < 0) {
      if (stack.empty()) break;
      cur = node(stack.back()).next;
      stack.pop_back();
      continue;
    }
    const Inline& n = node(cur);
    switch (n.kind) {
      case InlineKind::Text:
      case InlineKind::Code:
        escape_html(out, n.text);
        break;
      case InlineKind::SoftBreak:
      case InlineKind::LineBreak:
        out.push_back(' ');
        break;
      default:
        break;
    }
    if (n.first >= 0) {
      stack.push_back(cur);
      cur = n.first;
    } else {
      cur = n.next;
    }
  }
}

}  // namespace

void render_inlines(const InlineTree& tree, std::string& out) {
  auto node = [&](int i) -> const Inline& { return tree.nodes[static_cast<std::size_t>(i)]; };
  std::vector<int> stack;
  int cur = node(0).first;
  while (true) {
    if (cur < 0) {
      if (stack.empty()) break;
      const int parent = stack.back();
      stack.pop_back();
      switch (node(parent).kind) {
        case InlineKind::Emph: out.append("</em>"); break;
        case InlineKind::Strong: out.append("</strong>"); break;
        case InlineKind::Link: out.append("</a>"); break;
        default: break;
      }
      cur = node(parent).next;
      continue;
    }
    const Inline& n = node(cur);
    bool descend = false;
    switch (n.kind) {
      case InlineKind::Text:
        escape_html(out, n.text);
        break;
      case InlineKind::SoftBreak:
        out.push_back('\n');
        break;
      case InlineKind::LineBreak:
        out.append("<br />\n");
        break;
      case InlineKind::Code:
        out.append("<code>");
        escape_html(out, n.text);
        out.append("</code>");
        break;
      case InlineKind::Emph:
        out.append("<em>");
        descend = true;
        break;
      case InlineKind::Strong:
        out.append("<strong>");
        descend = true;
        break;
      case InlineKind::Link:
        out.append("<a href=\"");
        if (!is_dangerous_url(n.dest)) escape_href(out, n.dest);
        out.push_back('"');
        if (n.has_title) {
          out.append(" title=\"");
          escape_html(out, n.title);
          out.push_back('"');
        }
        out.push_back('>');
        descend = true;
        break;
      case InlineKind::Image:
        out.append("<img src=\"");
        if (!is_dangerous_url(n.dest)) escape_href(out, n.dest);
        out.append("\" alt=\"");
        render_alt_text(tree, cur, out);
        out.push_back('"');
        if (n.has_title) {
          out.append(" title=\"");
          escape_html(out, n.title);
          out.push_back('"');
        }
        out.append(" />");
        break;
      case InlineKind::Root:
        break;
    }
    if (descend && n.first >= 0) {
      stack.push_back(cur);
      cur = n.first;
    } else {
      if (descend) {
        // empty container: emit its closing tag right away
        switch (n.kind) {
          case InlineKind::Emph: out.append("</em>"); break;
          case InlineKind::Strong: out.append("</strong>"); break;
          case InlineKind::Link: out.append("</a>"); break;
          default: break;
        }
      }
      cur = n.next;
    }
  }
}

namespace {

class HtmlRenderer {
 public:
  HtmlRenderer(const std::vector<Block>& blocks, std::string& out) : b_(blocks), out_(out) {}

  void render_children(int idx) {
    for (int c = blk(idx).first_child; c >= 0; c = blk(c).next) render(c);
  }

 private:
  const Block& blk(int i) const { return b_[static_cast<std::size_t>(i)]; }

  void cr() {
    if (!out_.empty() && out_.back() != '\n') out_.push_back('\n');
  }

  void render_inline_content(const Block& b) {
    parse_inlines(b.content, tree_);
    render_inlines(tree_, out_);
  }

  void render(int idx) {
    const Block& b = blk(idx);
    switch (b.kind) {
      case BlockKind::Document:
        render_children(idx);
        break;
      case BlockKind::BlockQuote:
        cr();
        out_.append("<blockquote>\n");
        render_children(idx);
        cr();
        out_.append("</blockquote>\n");
        break;
      case BlockKind::List:
        cr();
        if (!b.ordered) {
          out_.append("<ul>\n");
        } else if (b.start == 1) {
          out_.append("<ol>\n");
        } else {
          out_.append("<ol start=\"");
          out_.append(std::to_string(b.start));
          out_.append("\">\n");
        }
        render_children(idx);
        out_.append(b.ordered ? "</ol>\n" : "</ul>\n");
        break;
      case BlockKind::Item:
        cr();
        out_.append("<li>");
        render_children(idx);
        out_.append("</li>\n");
        break;
      case BlockKind::Paragraph: {
        bool tight = false;
        if (b.parent >= 0) {
          const int gp = blk(b.parent).parent;
          tight = gp >= 0 && blk(gp).kind == BlockKind::List && blk(gp).tight;
        }
        if (!tight) {
          cr();
          out_.append("<p>");
        }
        render_inline_content(b);
        if (!tight) out_.append("</p>\n");
        break;
      }
      case BlockKind::Heading: {
        cr();
        const std::string tag = "h" + std::to_string(b.level);
        out_.append("<").append(tag).append(">");
        render_inline_content(b);
        out_.append("</").append(tag).append(">\n");
        break;
      }
      case BlockKind::ThematicBreak:
        cr();
        out_.append("<hr />\n");
        break;
      case BlockKind::CodeBlock: {
        cr();
        if (b.info.empty()) {
          out_.append("<pre><code>");
        } else {
          std::size_t end = 0;
          while (end < b.info.size() && !is_space_char(static_cast<unsigned char>(b.info[end]))) ++end;
          const std::string_view word(b.info.data(), end);
          out_.append("<pre><code class=\"");
          if (word.substr(0, 9) != "language-") out_.append("language-");
          escape_html(out_, word);
          out_.append("\">");
        }
        escape_html(out_, b.content);
        out_.append("</code></pre>\n");
        break;
      }
    }
  }

  const std::vector<Block>& b_;
  std::string& out_;
  InlineTree tree_;
};

}  // namespace

}  // namespace md_detail

std::string markdown_to_html(std::string_view markdown) {
  std::vector<md_detail::Block> blocks;
  md_detail::parse_blocks(markdown, blocks);
  std::string out;
  out.reserve(markdown.size() + markdown.size() / 2);
  md_detail::HtmlRenderer renderer(blocks, out);
  renderer.render_children(0);
  return out;
}

}  // namespace sitegen
