// Package protocol implements the line-oriented text protocol of the order
// book command-line tool: parsing commands, formatting events, and a Run loop
// that drives an [orderbook.Book] from a reader to a writer.
//
// Input is a count line N followed by N command lines:
//
//	LIMIT <id> <side> <price> <qty> [IOC|FOK]
//	MARKET <id> <side> <qty>
//	CANCEL <id>
//	REPLACE <id> <price> <qty>
//	BOOK
//
// Output is one event per line; see [AppendEvent].
package protocol
