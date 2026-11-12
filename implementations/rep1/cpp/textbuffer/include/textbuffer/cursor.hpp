#pragma once

/// \file cursor.hpp
/// Cursors, selections and the normalization that merges colliding cursors.

#include <cstdint>
#include <optional>
#include <vector>

#include "textbuffer/position.hpp"

namespace textbuffer {

/// A caret with an optional selection.
struct Cursor {
    /// Where the caret is.
    Position head;
    /// The other end of the selection; absent when there is no selection. It
    /// is never equal to #head.
    std::optional<Position> anchor;
    /// Exactly one cursor of a cursor set is primary.
    bool primary = false;
    /// The column remembered for vertical movement.
    std::uint32_t goal = 0;

    bool hasSelection() const noexcept { return anchor.has_value(); }
    /// The smaller end of the range (the head when there is no selection).
    Position start() const noexcept { return anchor && *anchor < head ? *anchor : head; }
    /// The larger end of the range (the head when there is no selection).
    Position end() const noexcept { return anchor && head < *anchor ? *anchor : head; }

    friend bool operator==(const Cursor&, const Cursor&) = default;
};

/// Normalizes a cursor list in place: stable-sorts by range start ascending
/// (ties: range end descending), then merges cursors whose ranges collide.
///
/// Two cursors merge when either has no selection and the later one starts at
/// or before the end of the earlier one, or when both have selections and the
/// later one starts strictly before the end of the earlier one. The merged
/// cursor covers the union, keeps the direction and goal column of the first,
/// and is primary if either was. O(C log C), or O(C) when already sorted.
void normalize(std::vector<Cursor>& cursors);

}  // namespace textbuffer
