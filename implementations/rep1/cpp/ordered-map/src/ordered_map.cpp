#include "ordered_map/ordered_map.hpp"

#include <algorithm>

namespace ordered_map {

OrderedMap::OrderedMap() { nodes_.emplace_back(); }  // index 0: the null node

void OrderedMap::clear() {
    nodes_.clear();
    nodes_.emplace_back();
    free_.clear();
    root_ = kNil;
}

std::uint32_t OrderedMap::allocate(key_type key, std::string_view value) {
    std::uint32_t n;
    if (!free_.empty()) {
        n = free_.back();
        free_.pop_back();
    } else {
        n = static_cast<std::uint32_t>(nodes_.size());
        nodes_.emplace_back();
    }
    Node& node = nodes_[n];
    node.key = key;
    node.value.assign(value.data(), value.size());
    node.left = node.right = kNil;
    node.size = 1;
    node.height = 1;
    return n;
}

void OrderedMap::release(std::uint32_t n) {
    nodes_[n].value.clear();
    free_.push_back(n);
}

void OrderedMap::update(std::uint32_t n) {
    Node& node = nodes_[n];
    const Node& l = nodes_[node.left];
    const Node& r = nodes_[node.right];
    node.height = 1 + std::max(l.height, r.height);
    node.size = 1 + l.size + r.size;
}

std::uint32_t OrderedMap::rotate_left(std::uint32_t n) {
    std::uint32_t r = nodes_[n].right;
    nodes_[n].right = nodes_[r].left;
    nodes_[r].left = n;
    update(n);
    update(r);
    return r;
}

std::uint32_t OrderedMap::rotate_right(std::uint32_t n) {
    std::uint32_t l = nodes_[n].left;
    nodes_[n].left = nodes_[l].right;
    nodes_[l].right = n;
    update(n);
    update(l);
    return l;
}

std::uint32_t OrderedMap::rebalance(std::uint32_t n) {
    update(n);
    const std::int32_t bf =
        nodes_[nodes_[n].left].height - nodes_[nodes_[n].right].height;
    if (bf > 1) {
        std::uint32_t l = nodes_[n].left;
        if (nodes_[nodes_[l].left].height < nodes_[nodes_[l].right].height)
            nodes_[n].left = rotate_left(l);
        return rotate_right(n);
    }
    if (bf < -1) {
        std::uint32_t r = nodes_[n].right;
        if (nodes_[nodes_[r].right].height < nodes_[nodes_[r].left].height)
            nodes_[n].right = rotate_right(r);
        return rotate_left(n);
    }
    return n;
}

std::uint32_t OrderedMap::find_node(key_type key) const {
    std::uint32_t n = root_;
    while (n != kNil) {
        const Node& node = nodes_[n];
        if (key < node.key) n = node.left;
        else if (key > node.key) n = node.right;
        else return n;
    }
    return kNil;
}

std::uint32_t OrderedMap::insert_node(std::uint32_t n, std::uint32_t fresh) {
    if (n == kNil) return fresh;
    if (nodes_[fresh].key < nodes_[n].key) {
        std::uint32_t c = insert_node(nodes_[n].left, fresh);
        nodes_[n].left = c;
    } else {
        std::uint32_t c = insert_node(nodes_[n].right, fresh);
        nodes_[n].right = c;
    }
    return rebalance(n);
}

bool OrderedMap::insert(key_type key, std::string_view value) {
    if (std::uint32_t n = find_node(key); n != kNil) {
        nodes_[n].value.assign(value.data(), value.size());
        return false;
    }
    std::uint32_t fresh = allocate(key, value);
    root_ = insert_node(root_, fresh);
    return true;
}

std::uint32_t OrderedMap::extract_min(std::uint32_t n, std::uint32_t& out) {
    if (nodes_[n].left == kNil) {
        out = n;
        return nodes_[n].right;
    }
    std::uint32_t c = extract_min(nodes_[n].left, out);
    nodes_[n].left = c;
    return rebalance(n);
}

std::uint32_t OrderedMap::erase_key(std::uint32_t n, key_type key) {
    if (n == kNil) return kNil;
    if (key < nodes_[n].key) {
        std::uint32_t c = erase_key(nodes_[n].left, key);
        nodes_[n].left = c;
    } else if (key > nodes_[n].key) {
        std::uint32_t c = erase_key(nodes_[n].right, key);
        nodes_[n].right = c;
    } else {
        const std::uint32_t l = nodes_[n].left, r = nodes_[n].right;
        if (l == kNil || r == kNil) {
            release(n);
            return l == kNil ? r : l;
        }
        std::uint32_t m = kNil;
        std::uint32_t new_right = extract_min(r, m);
        nodes_[m].left = l;
        nodes_[m].right = new_right;
        release(n);
        n = m;
    }
    return rebalance(n);
}

bool OrderedMap::erase(key_type key) {
    if (find_node(key) == kNil) return false;
    root_ = erase_key(root_, key);
    return true;
}

const std::string* OrderedMap::find(key_type key) const {
    std::uint32_t n = find_node(key);
    return n == kNil ? nullptr : &nodes_[n].value;
}

std::optional<OrderedMap::key_type> OrderedMap::min() const {
    if (root_ == kNil) return std::nullopt;
    std::uint32_t n = root_;
    while (nodes_[n].left != kNil) n = nodes_[n].left;
    return nodes_[n].key;
}

std::optional<OrderedMap::key_type> OrderedMap::max() const {
    if (root_ == kNil) return std::nullopt;
    std::uint32_t n = root_;
    while (nodes_[n].right != kNil) n = nodes_[n].right;
    return nodes_[n].key;
}

std::optional<OrderedMap::key_type> OrderedMap::floor(key_type key) const {
    std::optional<key_type> best;
    std::uint32_t n = root_;
    while (n != kNil) {
        const Node& node = nodes_[n];
        if (node.key == key) return key;
        if (node.key < key) { best = node.key; n = node.right; }
        else n = node.left;
    }
    return best;
}

std::optional<OrderedMap::key_type> OrderedMap::ceil(key_type key) const {
    std::optional<key_type> best;
    std::uint32_t n = root_;
    while (n != kNil) {
        const Node& node = nodes_[n];
        if (node.key == key) return key;
        if (node.key > key) { best = node.key; n = node.left; }
        else n = node.right;
    }
    return best;
}

std::optional<OrderedMap::key_type> OrderedMap::successor(key_type key) const {
    std::optional<key_type> best;
    std::uint32_t n = root_;
    while (n != kNil) {
        const Node& node = nodes_[n];
        if (node.key > key) { best = node.key; n = node.left; }
        else n = node.right;
    }
    return best;
}

std::optional<OrderedMap::key_type> OrderedMap::predecessor(key_type key) const {
    std::optional<key_type> best;
    std::uint32_t n = root_;
    while (n != kNil) {
        const Node& node = nodes_[n];
        if (node.key < key) { best = node.key; n = node.right; }
        else n = node.left;
    }
    return best;
}

std::size_t OrderedMap::rank(key_type key) const {
    std::size_t count = 0;
    std::uint32_t n = root_;
    while (n != kNil) {
        const Node& node = nodes_[n];
        if (node.key < key) {
            count += nodes_[node.left].size + 1;
            n = node.right;
        } else {
            n = node.left;
        }
    }
    return count;
}

std::optional<OrderedMap::key_type> OrderedMap::select(std::uint64_t k) const {
    if (k >= size()) return std::nullopt;
    std::uint32_t n = root_;
    while (true) {
        const Node& node = nodes_[n];
        const std::uint64_t ls = nodes_[node.left].size;
        if (k < ls) n = node.left;
        else if (k == ls) return node.key;
        else { k -= ls + 1; n = node.right; }
    }
}

std::vector<OrderedMap::key_type> OrderedMap::range(key_type lo, key_type hi) const {
    std::vector<key_type> out;
    for_each_in_range(lo, hi, [&](key_type k, const std::string&) { out.push_back(k); });
    return out;
}

bool OrderedMap::validate_node(std::uint32_t n, const key_type* lo, const key_type* hi,
                               std::uint32_t& size, std::int32_t& height) const {
    if (n == kNil) { size = 0; height = 0; return true; }
    const Node& node = nodes_[n];
    if ((lo && node.key <= *lo) || (hi && node.key >= *hi)) return false;
    std::uint32_t ls, rs;
    std::int32_t lh, rh;
    if (!validate_node(node.left, lo, &node.key, ls, lh)) return false;
    if (!validate_node(node.right, &node.key, hi, rs, rh)) return false;
    if (lh - rh > 1 || rh - lh > 1) return false;
    size = 1 + ls + rs;
    height = 1 + std::max(lh, rh);
    return size == node.size && height == node.height;
}

bool OrderedMap::validate() const {
    std::uint32_t s;
    std::int32_t h;
    if (!validate_node(root_, nullptr, nullptr, s, h)) return false;
    return s + free_.size() + 1 == nodes_.size();
}

}  // namespace ordered_map
