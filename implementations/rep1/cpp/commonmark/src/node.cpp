#include "commonmark/node.h"

namespace commonmark {

Document::Document() {
  nodes_.emplace_back();  // the root, type Document
}

NodeId Document::create(NodeType type) {
  nodes_.emplace_back();
  nodes_.back().type = type;
  return static_cast<NodeId>(nodes_.size() - 1);
}

void Document::append_child(NodeId parent, NodeId child) {
  Node& p = (*this)[parent];
  Node& c = (*this)[child];
  c.parent = parent;
  c.next = kNoNode;
  c.prev = p.last_child;
  if (p.last_child != kNoNode) {
    (*this)[p.last_child].next = child;
  } else {
    p.first_child = child;
  }
  p.last_child = child;
}

void Document::insert_after(NodeId ref, NodeId node) {
  Node& r = (*this)[ref];
  Node& n = (*this)[node];
  n.parent = r.parent;
  n.prev = ref;
  n.next = r.next;
  if (r.next != kNoNode) {
    (*this)[r.next].prev = node;
  } else if (r.parent != kNoNode) {
    (*this)[r.parent].last_child = node;
  }
  r.next = node;
}

void Document::unlink(NodeId id) {
  Node& n = (*this)[id];
  if (n.prev != kNoNode) {
    (*this)[n.prev].next = n.next;
  } else if (n.parent != kNoNode) {
    (*this)[n.parent].first_child = n.next;
  }
  if (n.next != kNoNode) {
    (*this)[n.next].prev = n.prev;
  } else if (n.parent != kNoNode) {
    (*this)[n.parent].last_child = n.prev;
  }
  n.parent = n.prev = n.next = kNoNode;
}

void Document::move_run(NodeId first, NodeId last, NodeId new_parent) {
  Node& f = (*this)[first];
  Node& l = (*this)[last];
  const NodeId old_parent = f.parent;
  const NodeId before = f.prev;
  const NodeId after = l.next;

  // Close the gap in the old sibling list.
  if (before != kNoNode) {
    (*this)[before].next = after;
  } else if (old_parent != kNoNode) {
    (*this)[old_parent].first_child = after;
  }
  if (after != kNoNode) {
    (*this)[after].prev = before;
  } else if (old_parent != kNoNode) {
    (*this)[old_parent].last_child = before;
  }

  // Splice onto the end of the new parent.
  Node& np = (*this)[new_parent];
  f.prev = np.last_child;
  if (np.last_child != kNoNode) {
    (*this)[np.last_child].next = first;
  } else {
    np.first_child = first;
  }
  np.last_child = last;
  l.next = kNoNode;
  for (NodeId id = first;; id = (*this)[id].next) {
    (*this)[id].parent = new_parent;
    if (id == last) break;
  }
}

}  // namespace commonmark
