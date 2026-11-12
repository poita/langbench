// An indexed binary max-heap of variables ordered by an external activity
// array. Supports O(log n) insert, remove-max and key-increase, and O(1)
// membership tests.
#pragma once

#include <vector>

#include "sat/types.hpp"

namespace sat {

class VarHeap {
 public:
  /// `activity` must outlive the heap; it is read, never written.
  explicit VarHeap(const std::vector<double>& activity) : act_(activity) {}

  bool empty() const { return heap_.empty(); }
  int size() const { return static_cast<int>(heap_.size()); }

  bool contains(Var v) const {
    return v < static_cast<Var>(pos_.size()) && pos_[v] >= 0;
  }

  /// Insert `v` if it is not already present.
  void insert(Var v) {
    if (v >= static_cast<Var>(pos_.size())) pos_.resize(v + 1, -1);
    if (pos_[v] >= 0) return;
    pos_[v] = static_cast<int>(heap_.size());
    heap_.push_back(v);
    siftUp(pos_[v]);
  }

  /// Variable with the highest activity. Precondition: !empty().
  Var top() const { return heap_[0]; }

  /// Remove and return the variable with the highest activity.
  Var removeMax() {
    Var v = heap_[0];
    heap_[0] = heap_.back();
    pos_[heap_[0]] = 0;
    pos_[v] = -1;
    heap_.pop_back();
    if (!heap_.empty()) siftDown(0);
    return v;
  }

  /// Call after the activity of `v` has increased.
  void increased(Var v) {
    if (contains(v)) siftUp(pos_[v]);
  }

 private:
  void siftUp(int i) {
    Var v = heap_[i];
    while (i > 0) {
      int parent = (i - 1) >> 1;
      if (!(act_[v] > act_[heap_[parent]])) break;
      heap_[i] = heap_[parent];
      pos_[heap_[i]] = i;
      i = parent;
    }
    heap_[i] = v;
    pos_[v] = i;
  }

  void siftDown(int i) {
    Var v = heap_[i];
    const int n = static_cast<int>(heap_.size());
    for (;;) {
      int child = 2 * i + 1;
      if (child >= n) break;
      if (child + 1 < n && act_[heap_[child + 1]] > act_[heap_[child]]) ++child;
      if (!(act_[heap_[child]] > act_[v])) break;
      heap_[i] = heap_[child];
      pos_[heap_[i]] = i;
      i = child;
    }
    heap_[i] = v;
    pos_[v] = i;
  }

  const std::vector<double>& act_;
  std::vector<Var> heap_;
  std::vector<int> pos_;  // position in heap_, or -1
};

}  // namespace sat
