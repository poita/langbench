// Indexed binary max-heap of variables keyed by an external activity array.
#pragma once

#include <cstddef>
#include <vector>

#include "sat/types.hpp"

namespace sat {

/// A priority queue of variables ordered by decreasing activity.
///
/// The heap does not own the activities; it holds a reference to a vector that
/// the caller keeps in sync. After *increasing* a variable's activity call
/// increased(); the heap property is otherwise maintained by insert()/pop().
/// All operations are O(log n) except contains()/empty()/size(), which are O(1).
class VarHeap {
public:
    explicit VarHeap(const std::vector<double>& activity) : activity_(activity) {}

    bool empty() const { return heap_.empty(); }
    std::size_t size() const { return heap_.size(); }
    bool contains(Var v) const { return v < static_cast<Var>(pos_.size()) && pos_[v] >= 0; }

    /// Inserts `v` (no-op if already present).
    void insert(Var v);
    /// Restores the heap property after the activity of `v` increased.
    void increased(Var v);
    /// Removes and returns the variable of highest activity. Heap must be non-empty.
    Var pop_max();
    /// Removes all elements.
    void clear();

private:
    bool higher(Var a, Var b) const { return activity_[a] > activity_[b]; }
    void sift_up(int i);
    void sift_down(int i);

    const std::vector<double>& activity_;
    std::vector<Var> heap_;
    std::vector<int> pos_;  // position of each variable in heap_, or -1
};

}  // namespace sat
