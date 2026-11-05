package orderbook

import "errors"

// Side is the side of an order: buy (bid) or sell (ask).
type Side uint8

// The two sides of the book.
const (
	Buy Side = iota
	Sell
)

// String returns "BUY" or "SELL".
func (s Side) String() string {
	if s == Buy {
		return "BUY"
	}
	return "SELL"
}

// TimeInForce selects what happens to the unfilled part of a limit order.
type TimeInForce uint8

const (
	// GTC (good till cancelled) rests any remainder in the book.
	GTC TimeInForce = iota
	// IOC (immediate or cancel) discards any remainder.
	IOC
	// FOK (fill or kill) executes completely or not at all.
	FOK
)

// String returns the protocol flag for the time in force ("" for GTC).
func (t TimeInForce) String() string {
	switch t {
	case IOC:
		return "IOC"
	case FOK:
		return "FOK"
	}
	return ""
}

// Kind identifies a command in the text protocol.
type Kind uint8

// The command kinds.
const (
	KindLimit Kind = iota
	KindMarket
	KindCancel
	KindReplace
	KindBook
)

// Command is one parsed command of the text protocol. Which fields are
// meaningful depends on Kind:
//
//	KindLimit:   ID, Side, Price, Qty, TIF
//	KindMarket:  ID, Side, Qty
//	KindCancel:  ID
//	KindReplace: ID, Price, Qty
//	KindBook:    (none)
//
// ID aliases the buffer the command was parsed from.
type Command struct {
	Kind  Kind
	Side  Side
	TIF   TimeInForce
	ID    []byte
	Price int64
	Qty   int64

	rank int32 // index of Price in the script's price table
}

// Level is one non-empty price level of the book.
type Level struct {
	Price  int64 // price of the level
	Qty    int64 // sum of the remaining quantities of its orders
	Orders int   // number of orders resting at the level
}

// Errors returned by Book methods and the parser.
var (
	// ErrUnknownPrice means a price is not in the book's price table.
	ErrUnknownPrice = errors.New("orderbook: price not in the book's price table")
	// ErrInvalidQty means a quantity was not positive.
	ErrInvalidQty = errors.New("orderbook: quantity must be positive")
	// ErrDuplicateID means a limit order used the id of an order that is
	// still resting.
	ErrDuplicateID = errors.New("orderbook: id is already resting")
	// ErrBadPrices means a price table was not strictly ascending or
	// contained a non-positive price.
	ErrBadPrices = errors.New("orderbook: prices must be positive and strictly ascending")
	// ErrBadCommand means a Command had an unknown Kind.
	ErrBadCommand = errors.New("orderbook: unknown command kind")
)
