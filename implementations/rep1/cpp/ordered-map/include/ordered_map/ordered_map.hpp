// ordered_map.hpp - an AVL tree mapping int64_t keys to short strings, with
// subtree-size augmentation for order statistics.
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace ordered_map {

/// Ordered map from `std::int64_t` to `std::string`.
///
/// Implemented as a self-balancing AVL tree whose nodes live in a contiguous
/// arena (32-bit indices instead of pointers; index 0 is the null node).
/// Every node stores its subtree size, so `rank` and `select` are O(log n).
///
/// Complexity: insert, erase, find, floor, ceil, successor, predecessor, rank,
/// select, min, max are all O(log n); size is O(1); for_each_in_range is
/// O(log n + r) where r is the number of keys visited.
///
/// Not thread-safe for concurrent mutation.
class OrderedMap {
public:
    using key_type = std::int64_t;

    OrderedMap();

    /// Number of keys stored.
    std::size_t size() const noexcept { return nodes_[root_].size; }
    bool empty() const noexcept { return root_ == kNil; }
    void clear();

    /// Inserts `key` with `value`, or replaces the value if present.
    /// Returns true if the key was newly inserted, false if it was updated.
    bool insert(key_type key, std::string_view value);

    /// Removes `key`. Returns true if it was present.
    bool erase(key_type key);

    /// Pointer to the value stored under `key`, or nullptr. The pointer is
    /// invalidated by any subsequent mutation.
    const std::string* find(key_type key) const;
    bool contains(key_type key) const { return find(key) != nullptr; }

    std::optional<key_type> min() const;
    std::optional<key_type> max() const;

    /// Largest key <= `key`.
    std::optional<key_type> floor(key_type key) const;
    /// Smallest key >= `key`.
    std::optional<key_type> ceil(key_type key) const;
    /// Smallest key > `key` (never overflows, even for INT64_MAX).
    std::optional<key_type> successor(key_type key) const;
    /// Largest key < `key`.
    std::optional<key_type> predecessor(key_type key) const;

    /// Number of stored keys strictly less than `key`; `key` need not exist.
    std::size_t rank(key_type key) const;
    /// The k-th smallest key (0-based), or nullopt if k >= size().
    std::optional<key_type> select(std::uint64_t k) const;

    /// Calls `fn(key, value)` for every key in [lo, hi] in ascending order.
    /// Does nothing when lo > hi. The map must not be modified by `fn`.
    template <class Fn>
    void for_each_in_range(key_type lo, key_type hi, Fn&& fn) const {
        if (lo > hi) return;
        std::vector<std::uint32_t> stack;
        stack.reserve(64);
        std::uint32_t n = root_;
        while (n != kNil || !stack.empty()) {
            while (n != kNil) {
                if (nodes_[n].key >= lo) {
                    stack.push_back(n);
                    n = nodes_[n].left;
                } else {
                    n = nodes_[n].right;
                }
            }
            if (stack.empty()) break;
            n = stack.back();
            stack.pop_back();
            if (nodes_[n].key > hi) break;
            fn(nodes_[n].key, nodes_[n].value);
            n = nodes_[n].right;
        }
    }

    /// Keys in [lo, hi] in ascending order.
    std::vector<key_type> range(key_type lo, key_type hi) const;

    /// Checks the BST order, AVL balance, heights and sizes. For tests.
    bool validate() const;

private:
    static constexpr std::uint32_t kNil = 0;

    struct Node {
        key_type key = 0;
        std::string value;
        std::uint32_t left = kNil;
        std::uint32_t right = kNil;
        std::uint32_t size = 0;
        std::int32_t height = 0;
    };

    std::uint32_t allocate(key_type key, std::string_view value);
    void release(std::uint32_t n);
    void update(std::uint32_t n);
    std::uint32_t rotate_left(std::uint32_t n);
    std::uint32_t rotate_right(std::uint32_t n);
    std::uint32_t rebalance(std::uint32_t n);
    std::uint32_t insert_node(std::uint32_t n, std::uint32_t fresh);
    std::uint32_t erase_key(std::uint32_t n, key_type key);
    std::uint32_t extract_min(std::uint32_t n, std::uint32_t& out);
    std::uint32_t find_node(key_type key) const;
    bool validate_node(std::uint32_t n, const key_type* lo, const key_type* hi,
                       std::uint32_t& size, std::int32_t& height) const;

    std::vector<Node> nodes_;
    std::vector<std::uint32_t> free_;
    std::uint32_t root_ = kNil;
};

}  // namespace ordered_map
