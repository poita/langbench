#include "textbuffer/cursor.hpp"

#include <algorithm>

namespace textbuffer {

namespace {

// Strict "comes first" order used by normalization.
bool comesBefore(const Cursor& a, const Cursor& b) {
    const Position sa = a.start(), sb = b.start();
    if (sa != sb) return sa < sb;
    return a.end() > b.end();
}

}  // namespace

void normalize(std::vector<Cursor>& cursors) {
    if (cursors.size() < 2) return;
    if (!std::is_sorted(cursors.begin(), cursors.end(), comesBefore)) {
        std::stable_sort(cursors.begin(), cursors.end(), comesBefore);
    }

    std::size_t out = 0;  // index of the current group's merged cursor
    for (std::size_t i = 1; i < cursors.size(); ++i) {
        Cursor& cur = cursors[out];
        const Cursor& c = cursors[i];
        const bool joins = (!cur.hasSelection() || !c.hasSelection())
                               ? c.start() <= cur.end()
                               : c.start() < cur.end();
        if (!joins) {
            cursors[++out] = c;
            continue;
        }
        const Position start = cur.start();
        const Position end = std::max(cur.end(), c.end());
        const bool backward = cur.hasSelection() && cur.head < *cur.anchor;
        if (start == end) {
            cur.head = start;
            cur.anchor.reset();
        } else if (backward) {
            cur.head = start;
            cur.anchor = end;
        } else {
            cur.head = end;
            cur.anchor = start;
        }
        cur.primary = cur.primary || c.primary;
    }
    cursors.resize(out + 1);
}

}  // namespace textbuffer
