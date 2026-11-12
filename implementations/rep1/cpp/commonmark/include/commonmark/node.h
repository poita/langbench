// commonmark/node.h - the document tree.
//
// A parsed document is a tree of `Node`s stored in one contiguous arena owned
// by a `Document`. Nodes refer to each other by `NodeId` (an index into the
// arena) rather than by pointer, so a document is cheap to copy or move and
// can be destroyed without recursion however deeply it is nested.
#ifndef COMMONMARK_NODE_H
#define COMMONMARK_NODE_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace commonmark {

/// Index of a node inside its `Document`.
using NodeId = std::int32_t;

/// The "no node" value used for absent parents, children and siblings.
inline constexpr NodeId kNoNode = -1;

/// Every kind of node in the tree.
enum class NodeType : std::uint8_t {
  // Container blocks.
  Document,
  BlockQuote,
  List,
  Item,
  // Leaf blocks.
  Paragraph,
  Heading,
  ThematicBreak,
  CodeBlock,
  // Inlines.
  Text,
  SoftBreak,
  LineBreak,
  Code,
  Emph,
  Strong,
  Link,
  Image,
};

/// Whether a list uses bullet or ordered markers.
enum class ListType : std::uint8_t { None, Bullet, Ordered };

/// One node of the tree. Which fields are meaningful depends on `type`.
struct Node {
  NodeType type = NodeType::Document;

  NodeId parent = kNoNode;
  NodeId first_child = kNoNode;
  NodeId last_child = kNoNode;
  NodeId prev = kNoNode;
  NodeId next = kNoNode;

  /// Text, Code: the characters. CodeBlock: the (unescaped) content.
  /// Link, Image: the destination (before URL-encoding).
  /// While block parsing is in progress, Paragraph and Heading hold their raw
  /// source text here; the inline parser consumes and clears it.
  std::string literal;

  /// CodeBlock: the info string. Link, Image: the title (see `has_title`).
  std::string extra;

  /// Heading: level 1-6.
  int level = 0;

  /// Link, Image: true if a title is present (it may be empty).
  bool has_title = false;

  /// List: marker kind, the bullet character or the ordered delimiter
  /// (`.` or `)`), the start number (ordered lists) and tightness.
  ListType list_type = ListType::None;
  char list_delimiter = 0;
  int list_start = 0;
  bool list_tight = false;

  const std::string& destination() const noexcept { return literal; }
  const std::string& title() const noexcept { return extra; }
  const std::string& info() const noexcept { return extra; }
  bool is_inline() const noexcept { return type >= NodeType::Text; }
};

/// An arena of nodes forming a tree rooted at `root()`.
class Document {
 public:
  Document();

  /// The root (always a `NodeType::Document` node, id 0).
  NodeId root() const noexcept { return 0; }

  /// Number of nodes ever created in the arena.
  std::size_t size() const noexcept { return nodes_.size(); }

  const Node& operator[](NodeId id) const { return nodes_[static_cast<std::size_t>(id)]; }
  Node& operator[](NodeId id) { return nodes_[static_cast<std::size_t>(id)]; }

  /// Creates a detached node. Invalidates references to existing nodes.
  NodeId create(NodeType type);

  /// Appends a detached `child` as the last child of `parent`.
  void append_child(NodeId parent, NodeId child);

  /// Inserts the detached node `node` right after `ref` (a child of some parent).
  void insert_after(NodeId ref, NodeId node);

  /// Detaches `id` from its parent and siblings (its own children stay).
  void unlink(NodeId id);

  /// Moves the sibling run `first..last` (inclusive, in order) out of its
  /// parent and appends it to `new_parent`. Cost is linear in the run length.
  void move_run(NodeId first, NodeId last, NodeId new_parent);

 private:
  std::vector<Node> nodes_;
};

}  // namespace commonmark

#endif  // COMMONMARK_NODE_H
