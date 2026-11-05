package sim

import "strconv"

// AppendReport appends the textual report of the simulation to dst:
//
//	sim <attempts> <deliveries>
//	attempt <seq> <ev-id> <ep-id> <n> <ts> <outcome> <code>   (per attempt)
//	delivery <ev-id> <ep-id> <status> <attempts> <last-ts> <header>
//
// Every line, including the last, ends in a newline.
func (r *Result) AppendReport(dst []byte) []byte {
	dst = append(dst, "sim "...)
	dst = strconv.AppendInt(dst, int64(len(r.Attempts)), 10)
	dst = append(dst, ' ')
	dst = strconv.AppendInt(dst, int64(len(r.Deliveries)), 10)
	dst = append(dst, '\n')
	for i, a := range r.Attempts {
		d := &r.Deliveries[a.Delivery]
		dst = append(dst, "attempt "...)
		dst = strconv.AppendInt(dst, int64(i+1), 10)
		dst = append(dst, ' ')
		dst = append(dst, r.Events[d.Event].ID...)
		dst = append(dst, ' ')
		dst = append(dst, r.Endpoints[d.Endpoint].ID...)
		dst = append(dst, ' ')
		dst = strconv.AppendInt(dst, int64(a.N), 10)
		dst = append(dst, ' ')
		dst = strconv.AppendInt(dst, a.Time, 10)
		dst = append(dst, ' ')
		dst = append(dst, a.Outcome.String()...)
		dst = append(dst, ' ')
		if a.Code == Timeout {
			dst = append(dst, '-')
		} else {
			dst = strconv.AppendInt(dst, int64(a.Code), 10)
		}
		dst = append(dst, '\n')
	}
	for i := range r.Deliveries {
		d := &r.Deliveries[i]
		dst = append(dst, "delivery "...)
		dst = append(dst, r.Events[d.Event].ID...)
		dst = append(dst, ' ')
		dst = append(dst, r.Endpoints[d.Endpoint].ID...)
		dst = append(dst, ' ')
		dst = append(dst, d.Status.String()...)
		dst = append(dst, ' ')
		dst = strconv.AppendInt(dst, int64(d.Attempts), 10)
		dst = append(dst, ' ')
		if d.Attempts == 0 {
			dst = append(dst, '-')
		} else {
			dst = strconv.AppendInt(dst, d.LastTime, 10)
		}
		dst = append(dst, ' ')
		dst = append(dst, d.Header...)
		dst = append(dst, '\n')
	}
	return dst
}
