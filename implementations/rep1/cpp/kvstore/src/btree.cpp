#include "tessera/btree.hpp"

#include <algorithm>

#include "tessera/limits.hpp"

namespace tessera {
namespace {

/// Smallest i with key <= cells[i].key, or cells.size().
std::size_t child_index(const Node& n, std::string_view key) {
  auto it = std::lower_bound(n.cells.begin(), n.cells.end(), key,
                             [](const Cell& c, std::string_view k) {
                               return std::string_view(c.key) < k;
                             });
  return static_cast<std::size_t>(it - n.cells.begin());
}

std::uint32_t child_at(const Node& n, std::size_t i) {
  return i < n.cells.size() ? n.cells[i].child : n.link;
}

/// The split point of 12.3: smallest m in 1..n-1 with 2*P[m] >= T.
std::size_t split_point(const Node& n) {
  std::size_t total = used(n);
  std::size_t prefix = 0;
  for (std::size_t m = 1; m < n.cells.size(); ++m) {
    prefix += cell_cost(n.type, n.cells[m - 1]);
    if (2 * prefix >= total) return m;
  }
  return n.cells.size() - 1;
}

}  // namespace

BTree::BTree(Pager& pager, std::uint32_t& root, Kind kind)
    : pager_(pager), root_(root), kind_(kind) {}

std::uint32_t BTree::descend(std::string_view key, std::vector<Frame>& path, Node& leaf) const {
  std::uint32_t p = root_;
  while (true) {
    Node node = load(p);
    if (node.is_leaf()) {
      leaf = std::move(node);
      return p;
    }
    std::size_t i = child_index(node, key);
    std::uint32_t next = child_at(node, i);
    path.push_back(Frame{p, std::move(node), i});
    p = next;
  }
}

std::optional<Cell> BTree::find(std::string_view key) const {
  if (root_ == 0) return std::nullopt;
  std::vector<Frame> path;
  Node leaf;
  descend(key, path, leaf);
  std::size_t i = child_index(leaf, key);
  if (i < leaf.cells.size() && leaf.cells[i].key == key) return std::move(leaf.cells[i]);
  return std::nullopt;
}

void BTree::insert(Cell cell) {
  if (root_ == 0) {
    std::uint32_t r = pager_.allocate();
    Node empty;
    empty.type = leaf_type();
    pager_.write(r, encode_node(empty));
    root_ = r;
  }
  std::vector<Frame> path;
  Node leaf;
  std::uint32_t page = descend(cell.key, path, leaf);
  std::size_t i = child_index(leaf, cell.key);
  if (i < leaf.cells.size() && leaf.cells[i].key == cell.key) {
    leaf.cells[i] = std::move(cell);
  } else {
    leaf.cells.insert(leaf.cells.begin() + static_cast<std::ptrdiff_t>(i), std::move(cell));
  }
  store(path, page, std::move(leaf));
}

// Writes `node`, splitting it (and its ancestors) while it overflows. `path`
// holds the ancestors of `node`.
void BTree::store(std::vector<Frame>& path, std::uint32_t page, Node node) {
  while (true) {
    if (used(node) <= kCapacity) {
      pager_.write(page, encode_node(node));
      return;
    }
    std::size_t m = split_point(node);
    std::uint32_t right_page = pager_.allocate();
    Node right;
    right.type = node.type;
    std::string sep;
    if (node.is_leaf()) {
      right.cells.assign(std::make_move_iterator(node.cells.begin() + static_cast<std::ptrdiff_t>(m)),
                         std::make_move_iterator(node.cells.end()));
      right.link = node.link;
      node.link = right_page;
      node.cells.resize(m);
      sep = node.cells[m - 1].key;
    } else {
      sep = node.cells[m - 1].key;
      std::uint32_t promoted = node.cells[m - 1].child;
      right.cells.assign(std::make_move_iterator(node.cells.begin() + static_cast<std::ptrdiff_t>(m)),
                         std::make_move_iterator(node.cells.end()));
      right.link = node.link;
      node.link = promoted;
      node.cells.resize(m - 1);
    }
    pager_.write(right_page, encode_node(right));
    pager_.write(page, encode_node(node));

    if (path.empty()) {
      std::uint32_t new_root = pager_.allocate();
      Node nr;
      nr.type = PageType::Interior;
      Cell c;
      c.key = sep;
      c.child = page;
      nr.cells.push_back(std::move(c));
      nr.link = right_page;
      pager_.write(new_root, encode_node(nr));
      root_ = new_root;
      return;
    }
    Frame parent = std::move(path.back());
    path.pop_back();
    Cell c;
    c.key = sep;
    c.child = page;
    if (parent.index == parent.node.cells.size()) {
      parent.node.cells.push_back(std::move(c));
      parent.node.link = right_page;
    } else {
      parent.node.cells[parent.index].child = right_page;
      parent.node.cells.insert(parent.node.cells.begin() + static_cast<std::ptrdiff_t>(parent.index),
                               std::move(c));
    }
    page = parent.page;
    node = std::move(parent.node);
  }
}

bool BTree::erase(std::string_view key) {
  if (root_ == 0) return false;
  std::vector<Frame> path;
  Node leaf;
  std::uint32_t page = descend(key, path, leaf);
  std::size_t i = child_index(leaf, key);
  if (i >= leaf.cells.size() || leaf.cells[i].key != key) return false;
  leaf.cells.erase(leaf.cells.begin() + static_cast<std::ptrdiff_t>(i));

  if (path.empty()) {
    if (leaf.cells.empty()) {
      pager_.free_page(page);
      root_ = 0;
    } else {
      pager_.write(page, encode_node(leaf));
    }
    return true;
  }
  if (used(leaf) >= kMinFill) {
    pager_.write(page, encode_node(leaf));
    return true;
  }
  rebalance(path, page, std::move(leaf));
  return true;
}

// Repairs an underflowing page `n` (12.5): borrow left, borrow right, merge
// left, merge right; a merge may make the parent underflow in turn.
void BTree::rebalance(std::vector<Frame>& path, std::uint32_t npage, Node n) {
  while (true) {
    Frame f = std::move(path.back());
    path.pop_back();
    Node& P = f.node;
    const std::size_t j = f.index;
    const std::size_t nP = P.cells.size();
    const PageType type = n.type;

    std::uint32_t lpage = 0, rpage = 0;
    Node L, R;
    bool has_l = j >= 1, has_r = j < nP;
    if (has_l) {
      lpage = P.cells[j - 1].child;
      L = load(lpage);
    }
    if (has_r) {
      rpage = child_at(P, j + 1);
      R = load(rpage);
    }

    // 1. borrow from the left
    if (has_l && !L.cells.empty() &&
        used(L) - cell_cost(type, L.cells.back()) >= kMinFill) {
      if (n.is_leaf()) {
        n.cells.insert(n.cells.begin(), std::move(L.cells.back()));
        L.cells.pop_back();
        P.cells[j - 1].key = L.cells.back().key;
      } else {
        Cell c;
        c.key = P.cells[j - 1].key;
        c.child = L.link;
        n.cells.insert(n.cells.begin(), std::move(c));
        P.cells[j - 1].key = L.cells.back().key;
        L.link = L.cells.back().child;
        L.cells.pop_back();
      }
      pager_.write(lpage, encode_node(L));
      pager_.write(npage, encode_node(n));
      store(path, f.page, std::move(P));
      return;
    }
    // 2. borrow from the right
    if (has_r && !R.cells.empty() &&
        used(R) - cell_cost(type, R.cells.front()) >= kMinFill) {
      if (n.is_leaf()) {
        n.cells.push_back(std::move(R.cells.front()));
        R.cells.erase(R.cells.begin());
        P.cells[j].key = n.cells.back().key;
      } else {
        Cell c;
        c.key = P.cells[j].key;
        c.child = n.link;
        n.cells.push_back(std::move(c));
        n.link = R.cells.front().child;
        P.cells[j].key = R.cells.front().key;
        R.cells.erase(R.cells.begin());
      }
      pager_.write(rpage, encode_node(R));
      pager_.write(npage, encode_node(n));
      store(path, f.page, std::move(P));
      return;
    }
    if (has_l) {
      // 3. merge with the left; the left page survives
      if (n.is_leaf()) {
        for (auto& c : n.cells) L.cells.push_back(std::move(c));
        L.link = n.link;
      } else {
        Cell c;
        c.key = P.cells[j - 1].key;
        c.child = L.link;
        L.cells.push_back(std::move(c));
        for (auto& x : n.cells) L.cells.push_back(std::move(x));
        L.link = n.link;
      }
      pager_.write(lpage, encode_node(L));
      P.cells.erase(P.cells.begin() + static_cast<std::ptrdiff_t>(j - 1));
      if (j == nP) {
        P.link = lpage;
      } else {
        P.cells[j - 1].child = lpage;
      }
      pager_.free_page(npage);
    } else {
      // 4. merge with the right; N survives
      if (n.is_leaf()) {
        for (auto& c : R.cells) n.cells.push_back(std::move(c));
        n.link = R.link;
      } else {
        Cell c;
        c.key = P.cells[j].key;
        c.child = n.link;
        n.cells.push_back(std::move(c));
        for (auto& x : R.cells) n.cells.push_back(std::move(x));
        n.link = R.link;
      }
      pager_.write(npage, encode_node(n));
      P.cells.erase(P.cells.begin() + static_cast<std::ptrdiff_t>(j));
      if (j + 1 == nP) {
        P.link = npage;
      } else {
        P.cells[j].child = npage;
      }
      pager_.free_page(rpage);
    }

    if (path.empty()) {
      if (P.cells.empty()) {
        root_ = P.link;
        pager_.free_page(f.page);
      } else {
        pager_.write(f.page, encode_node(P));
      }
      return;
    }
    if (used(P) >= kMinFill) {
      pager_.write(f.page, encode_node(P));
      return;
    }
    npage = f.page;
    n = std::move(P);
  }
}

void BTree::scan_from(std::string_view lower, const std::function<bool(const Cell&)>& visit) const {
  if (root_ == 0) return;
  std::vector<Frame> path;
  Node leaf;
  descend(lower, path, leaf);
  std::size_t i = child_index(leaf, lower);
  while (true) {
    for (; i < leaf.cells.size(); ++i)
      if (!visit(leaf.cells[i])) return;
    if (leaf.link == 0) return;
    leaf = load(leaf.link);
    i = 0;
  }
}

bool BTree::reverse_visit(std::uint32_t page, const std::optional<std::string>& upper,
                          const std::function<bool(const Cell&)>& visit) const {
  Node node = load(page);
  std::size_t n = node.cells.size();
  if (node.is_leaf()) {
    for (std::size_t i = n; i-- > 0;) {
      if (upper && !(node.cells[i].key < *upper)) continue;
      if (!visit(node.cells[i])) return false;
    }
    return true;
  }
  // Child i holds keys in (k[i-1], k[i]]; the link holds keys > k[n-1].
  for (std::size_t i = n + 1; i-- > 0;) {
    if (upper && i > 0 && node.cells[i - 1].key >= *upper) continue;
    if (!reverse_visit(child_at(node, i), upper, visit)) return false;
  }
  return true;
}

void BTree::scan_reverse(const std::optional<std::string>& upper,
                         const std::function<bool(const Cell&)>& visit) const {
  if (root_ == 0) return;
  reverse_visit(root_, upper, visit);
}

void BTree::free_subtree(std::uint32_t page, std::size_t& count) {
  Node node = load(page);
  if (!node.is_leaf()) {
    for (const auto& c : node.cells) free_subtree(c.child, count);
    free_subtree(node.link, count);
  }
  pager_.free_page(page);
  ++count;
}

std::size_t BTree::free_all() {
  std::size_t count = 0;
  if (root_ != 0) free_subtree(root_, count);
  root_ = 0;
  return count;
}

std::size_t BTree::height() const {
  std::size_t h = 0;
  std::uint32_t p = root_;
  while (p != 0) {
    ++h;
    Node node = load(p);
    if (node.is_leaf()) break;
    p = child_at(node, 0);
  }
  return h;
}

}  // namespace tessera
