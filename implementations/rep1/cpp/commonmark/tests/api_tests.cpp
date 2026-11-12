// The public tree API: Document operations and the parsed structure.
#include "test_helpers.h"

using commonmark::Document;
using commonmark::kNoNode;
using commonmark::NodeId;
using commonmark::NodeType;

namespace {

std::vector<NodeId> children(const Document& doc, NodeId id) {
  std::vector<NodeId> out;
  for (NodeId c = doc[id].first_child; c != kNoNode; c = doc[c].next) out.push_back(c);
  return out;
}

}  // namespace

TEST(Api, ParseBuildsExpectedTree) {
  const Document doc = commonmark::parse("# Hi\n\n- *a*\n- b\n");
  const auto top = children(doc, doc.root());
  ASSERT_EQ(top.size(), 2u);
  EXPECT_EQ(doc[top[0]].type, NodeType::Heading);
  EXPECT_EQ(doc[top[0]].level, 1);
  EXPECT_EQ(doc[top[1]].type, NodeType::List);
  EXPECT_TRUE(doc[top[1]].list_tight);
  EXPECT_EQ(doc[top[1]].list_type, commonmark::ListType::Bullet);
  const auto items = children(doc, top[1]);
  ASSERT_EQ(items.size(), 2u);
  const auto para = children(doc, items[0]);
  ASSERT_EQ(para.size(), 1u);
  const auto inlines = children(doc, para[0]);
  ASSERT_EQ(inlines.size(), 1u);
  EXPECT_EQ(doc[inlines[0]].type, NodeType::Emph);
  EXPECT_EQ(doc[doc[inlines[0]].first_child].literal, "a");
  EXPECT_EQ(doc[inlines[0]].parent, para[0]);
}

TEST(Api, ParentAndSiblingLinksAreConsistent) {
  const Document doc = commonmark::parse("a *b **c** d* [e](/f) ![g](/h) `i`\n\n> x\n\n1. y\n");
  for (std::size_t i = 0; i < doc.size(); ++i) {
    const NodeId id = static_cast<NodeId>(i);
    const auto kids = children(doc, id);
    for (std::size_t k = 0; k < kids.size(); ++k) {
      EXPECT_EQ(doc[kids[k]].parent, id);
      EXPECT_EQ(doc[kids[k]].prev, k == 0 ? kNoNode : kids[k - 1]);
    }
    EXPECT_EQ(doc[id].last_child, kids.empty() ? kNoNode : kids.back());
  }
}

TEST(Api, LinkNodeFields) {
  const Document doc = commonmark::parse("[t](/u \"ti\")");
  const NodeId para = doc[doc.root()].first_child;
  const NodeId link = doc[para].first_child;
  ASSERT_EQ(doc[link].type, NodeType::Link);
  EXPECT_EQ(doc[link].destination(), "/u");
  EXPECT_TRUE(doc[link].has_title);
  EXPECT_EQ(doc[link].title(), "ti");
}

TEST(Api, CodeBlockFields) {
  const Document doc = commonmark::parse("```rust extra\nfn main() {}\n```\n");
  const NodeId code = doc[doc.root()].first_child;
  ASSERT_EQ(doc[code].type, NodeType::CodeBlock);
  EXPECT_EQ(doc[code].info(), "rust extra");
  EXPECT_EQ(doc[code].literal, "fn main() {}\n");
}

TEST(Api, OrderedListStart) {
  const Document doc = commonmark::parse("7. a\n8. b");
  const NodeId list = doc[doc.root()].first_child;
  EXPECT_EQ(doc[list].list_type, commonmark::ListType::Ordered);
  EXPECT_EQ(doc[list].list_start, 7);
  EXPECT_EQ(doc[list].list_delimiter, '.');
}

TEST(Api, RenderIsRepeatable) {
  const Document doc = commonmark::parse("*a*");
  EXPECT_EQ(commonmark::render_html(doc), commonmark::render_html(doc));
  EXPECT_EQ(commonmark::render_html(doc), commonmark::to_html("*a*"));
}

TEST(Api, DocumentTreeSurgery) {
  Document doc;
  const NodeId a = doc.create(NodeType::Text);
  const NodeId b = doc.create(NodeType::Text);
  const NodeId c = doc.create(NodeType::Text);
  const NodeId d = doc.create(NodeType::Text);
  const NodeId box = doc.create(NodeType::Emph);
  doc.append_child(doc.root(), a);
  doc.append_child(doc.root(), b);
  doc.append_child(doc.root(), c);
  doc.append_child(doc.root(), d);
  doc.append_child(doc.root(), box);

  doc.move_run(b, c, box);
  EXPECT_EQ(children(doc, doc.root()), (std::vector<NodeId>{a, d, box}));
  EXPECT_EQ(children(doc, box), (std::vector<NodeId>{b, c}));
  EXPECT_EQ(doc[b].parent, box);
  EXPECT_EQ(doc[box].last_child, c);

  doc.unlink(d);
  EXPECT_EQ(children(doc, doc.root()), (std::vector<NodeId>{a, box}));
  doc.insert_after(a, d);
  EXPECT_EQ(children(doc, doc.root()), (std::vector<NodeId>{a, d, box}));
  doc.unlink(box);
  EXPECT_EQ(doc[doc.root()].last_child, d);
}

TEST(Api, ToHtmlAcceptsStringViewsWithEmbeddedNulFreeData) {
  const std::string_view view("ab", 1);
  EXPECT_EQ(commonmark::to_html(view), "<p>a</p>\n");
}
