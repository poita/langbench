package protocol

import (
	"strconv"

	"github.com/peteralexander/orderbook"
)

// AppendEvent appends the textual form of e, including the trailing newline,
// to dst and returns the extended slice:
//
//	TRADE <taker> <maker> <price> <qty>
//	REST <id>
//	CANCEL <id> <remaining>
//	REJECT <id>
//	FILLED <id>
//	BID <price> <total-qty> <n-orders>
//	ASK <price> <total-qty> <n-orders>
//	--
func AppendEvent(dst []byte, e orderbook.Event) []byte {
	switch e.Kind {
	case orderbook.Trade:
		dst = append(dst, "TRADE "...)
		dst = append(dst, e.ID...)
		dst = append(dst, ' ')
		dst = append(dst, e.MakerID...)
		dst = append(dst, ' ')
		dst = strconv.AppendUint(dst, e.Price, 10)
		dst = append(dst, ' ')
		dst = strconv.AppendUint(dst, e.Qty, 10)
	case orderbook.Rest:
		dst = append(dst, "REST "...)
		dst = append(dst, e.ID...)
	case orderbook.Cancel:
		dst = append(dst, "CANCEL "...)
		dst = append(dst, e.ID...)
		dst = append(dst, ' ')
		dst = strconv.AppendUint(dst, e.Qty, 10)
	case orderbook.Reject:
		dst = append(dst, "REJECT "...)
		dst = append(dst, e.ID...)
	case orderbook.Filled:
		dst = append(dst, "FILLED "...)
		dst = append(dst, e.ID...)
	case orderbook.Bid, orderbook.Ask:
		if e.Kind == orderbook.Bid {
			dst = append(dst, "BID "...)
		} else {
			dst = append(dst, "ASK "...)
		}
		dst = strconv.AppendUint(dst, e.Price, 10)
		dst = append(dst, ' ')
		dst = strconv.AppendUint(dst, e.Qty, 10)
		dst = append(dst, ' ')
		dst = strconv.AppendUint(dst, e.Orders, 10)
	case orderbook.EndBook:
		dst = append(dst, "--"...)
	}
	return append(dst, '\n')
}
