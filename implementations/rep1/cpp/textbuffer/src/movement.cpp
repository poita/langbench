#include "textbuffer/movement.hpp"

#include <algorithm>

namespace textbuffer {

namespace {

// Moves the head of `c`, updating the goal column for vertical movement.
void moveHead(Cursor& c, const Document& doc, Direction direction) {
    Position& h = c.head;
    const auto lastLine = static_cast<std::uint32_t>(doc.lineCount() - 1);
    const auto lineLength = [&](std::uint32_t l) { return static_cast<std::uint32_t>(doc.line(l).size()); };
    switch (direction) {
        case Direction::Left:
            if (h.col > 0) {
                --h.col;
            } else if (h.line > 0) {
                --h.line;
                h.col = lineLength(h.line);
            }
            break;
        case Direction::Right:
            if (h.col < lineLength(h.line)) {
                ++h.col;
            } else if (h.line < lastLine) {
                ++h.line;
                h.col = 0;
            }
            break;
        case Direction::Home:
            h.col = 0;
            break;
        case Direction::End:
            h.col = lineLength(h.line);
            break;
        case Direction::Up:
            if (h.line == 0) {
                h = {0, 0};
                c.goal = 0;
            } else {
                --h.line;
                h.col = std::min(c.goal, lineLength(h.line));
            }
            break;
        case Direction::Down:
            if (h.line == lastLine) {
                h.col = lineLength(h.line);
                c.goal = h.col;
            } else {
                ++h.line;
                h.col = std::min(c.goal, lineLength(h.line));
            }
            break;
    }
}

}  // namespace

Cursor moveCursor(const Cursor& cursor, const Document& doc, Direction direction, bool select) {
    Cursor c = cursor;
    if (!select) {
        if (c.hasSelection() && (direction == Direction::Left || direction == Direction::Right)) {
            c.head = direction == Direction::Left ? c.start() : c.end();
            c.anchor.reset();
            return c;
        }
        c.anchor.reset();
        moveHead(c, doc, direction);
        return c;
    }
    if (!c.hasSelection()) c.anchor = c.head;
    moveHead(c, doc, direction);
    if (c.anchor == c.head) c.anchor.reset();
    return c;
}

}  // namespace textbuffer
