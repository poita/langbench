#include "sat/heap.hpp"

#include <utility>

namespace sat {

void VarHeap::insert(Var v) {
    if (static_cast<std::size_t>(v) >= pos_.size()) pos_.resize(v + 1, -1);
    if (pos_[v] >= 0) return;
    pos_[v] = static_cast<int>(heap_.size());
    heap_.push_back(v);
    sift_up(pos_[v]);
}

void VarHeap::increased(Var v) {
    if (contains(v)) sift_up(pos_[v]);
}

Var VarHeap::pop_max() {
    Var top = heap_.front();
    Var last = heap_.back();
    heap_.pop_back();
    pos_[top] = -1;
    if (!heap_.empty()) {
        heap_[0] = last;
        pos_[last] = 0;
        sift_down(0);
    }
    return top;
}

void VarHeap::clear() {
    for (Var v : heap_) pos_[v] = -1;
    heap_.clear();
}

void VarHeap::sift_up(int i) {
    Var v = heap_[i];
    while (i > 0) {
        int parent = (i - 1) >> 1;
        if (!higher(v, heap_[parent])) break;
        heap_[i] = heap_[parent];
        pos_[heap_[i]] = i;
        i = parent;
    }
    heap_[i] = v;
    pos_[v] = i;
}

void VarHeap::sift_down(int i) {
    Var v = heap_[i];
    const int n = static_cast<int>(heap_.size());
    while (true) {
        int child = 2 * i + 1;
        if (child >= n) break;
        if (child + 1 < n && higher(heap_[child + 1], heap_[child])) ++child;
        if (!higher(heap_[child], v)) break;
        heap_[i] = heap_[child];
        pos_[heap_[i]] = i;
        i = child;
    }
    heap_[i] = v;
    pos_[v] = i;
}

}  // namespace sat
