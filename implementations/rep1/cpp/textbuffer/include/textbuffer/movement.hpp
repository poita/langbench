#pragma once

/// \file movement.hpp
/// Cursor movement.

#include "textbuffer/cursor.hpp"
#include "textbuffer/document.hpp"

namespace textbuffer {

enum class Direction { Left, Right, Up, Down, Home, End };

/// Moves \p cursor one step in \p direction. Without \p select a selection
/// collapses (left: to its start, right: to its end, other directions drop it
/// and move the head). With \p select the anchor is kept (or started at the
/// head) and the head moves; the selection vanishes if head meets anchor.
/// Only `Up` and `Down` use and update the goal column.
Cursor moveCursor(const Cursor& cursor, const Document& doc, Direction direction, bool select);

}  // namespace textbuffer
