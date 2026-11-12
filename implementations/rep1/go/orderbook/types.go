package orderbook

import "fmt"

// Side is the side of the book an order belongs to.
type Side uint8

const (
	// Buy orders rest as bids.
	Buy Side = iota
	// Sell orders rest as asks.
	Sell
)

// String returns "BUY" or "SELL".
func (s Side) String() string {
	if s == Buy {
		return "BUY"
	}
	return "SELL"
}

// TimeInForce controls what happens to the unfilled part of a limit order.
type TimeInForce uint8

const (
	// GTC (good till cancelled) rests any unfilled remainder in the book.
	GTC TimeInForce = iota
	// IOC (immediate or cancel) discards any unfilled remainder.
	IOC
	// FOK (fill or kill) executes completely or not at all.
	FOK
)

// String returns "", "IOC" or "FOK" as used on the wire (GTC has no flag).
func (t TimeInForce) String() string {
	switch t {
	case IOC:
		return "IOC"
	case FOK:
		return "FOK"
	}
	return ""
}

// CommandKind identifies the type of a [Command].
type CommandKind uint8

const (
	// CmdLimit submits a limit order.
	CmdLimit CommandKind = iota
	// CmdMarket submits a market order.
	CmdMarket
	// CmdCancel cancels a resting order.
	CmdCancel
	// CmdReplace modifies a resting order.
	CmdReplace
	// CmdBook requests a snapshot of the book.
	CmdBook
)

// Command is a request to a [Book]. Which fields are meaningful depends on
// Kind: Limit uses all of them; Market uses ID, Side and Qty; Cancel uses ID;
// Replace uses ID, Price and Qty; Book uses none.
type Command struct {
	Kind  CommandKind
	ID    string
	Side  Side
	Price uint64
	Qty   uint64
	TIF   TimeInForce
}

// EventKind identifies the type of an [Event].
type EventKind uint8

const (
	// Trade is a fill between a taker and a maker at the maker's price.
	Trade EventKind = iota
	// Rest reports that an order now rests in the book.
	Rest
	// Cancel reports that an order left the book, or never entered it, with
	// Qty unfilled.
	Cancel
	// Reject reports that a command was refused and nothing changed.
	Reject
	// Filled reports that an order's remaining quantity reached zero.
	Filled
	// Bid is one bid level of a snapshot.
	Bid
	// Ask is one ask level of a snapshot.
	Ask
	// EndBook terminates a snapshot.
	EndBook
)

// Event is one line of engine output.
//
// Field use by Kind:
//
//	Trade:   ID is the taker, MakerID the maker, Price the maker's price, Qty the traded quantity
//	Rest:    ID
//	Cancel:  ID, Qty (the unfilled remainder)
//	Reject:  ID
//	Filled:  ID
//	Bid/Ask: Price, Qty (level total), Orders (number of orders)
//	EndBook: no fields
type Event struct {
	Kind    EventKind
	ID      string
	MakerID string
	Price   uint64
	Qty     uint64
	Orders  uint64
}

// String renders the event in the textual wire format.
func (e Event) String() string {
	switch e.Kind {
	case Trade:
		return fmt.Sprintf("TRADE %s %s %d %d", e.ID, e.MakerID, e.Price, e.Qty)
	case Rest:
		return "REST " + e.ID
	case Cancel:
		return fmt.Sprintf("CANCEL %s %d", e.ID, e.Qty)
	case Reject:
		return "REJECT " + e.ID
	case Filled:
		return "FILLED " + e.ID
	case Bid:
		return fmt.Sprintf("BID %d %d %d", e.Price, e.Qty, e.Orders)
	case Ask:
		return fmt.Sprintf("ASK %d %d %d", e.Price, e.Qty, e.Orders)
	case EndBook:
		return "--"
	}
	return "?"
}

// Level is a snapshot of one price level.
type Level struct {
	Price  uint64 // price of the level
	Qty    uint64 // total remaining quantity of the orders in the level
	Orders int    // number of orders in the level
}
