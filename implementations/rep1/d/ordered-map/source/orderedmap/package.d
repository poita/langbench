/**
 * Ordered map from 64-bit signed integer keys to short string values.
 *
 * The map is a size-augmented AVL tree stored in a flat node pool, so every
 * operation (insert, remove, lookup, floor/ceil/succ/pred, rank/select) costs
 * $(I O(log n)) and a range listing costs $(I O(log n + r)).
 *
 * Modules:
 * $(UL
 *   $(LI `orderedmap.tree`     – the `OrderedMap` data structure)
 *   $(LI `orderedmap.outbuf`   – `OutBuffer`, a fast append-only byte buffer)
 *   $(LI `orderedmap.parse`    – hand-rolled integer parsing and formatting)
 *   $(LI `orderedmap.commands` – the line-oriented command interpreter)
 * )
 *
 * Example:
 * ---
 * import orderedmap;
 *
 * OrderedMap m;
 * m.insert(20, "b");
 * m.insert(10, "a");
 * assert(m.rank(20) == 1);
 * long k;
 * assert(m.ceil(11, k) && k == 20);
 * ---
 */
module orderedmap;

public import orderedmap.tree;
public import orderedmap.outbuf;
public import orderedmap.parse;
public import orderedmap.commands;
