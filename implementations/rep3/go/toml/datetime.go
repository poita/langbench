package toml

// num2 parses two ASCII digits at tok[i:i+2].
func num2(tok []byte, i int) (int, bool) {
	if i+2 > len(tok) || !isDigit(tok[i]) || !isDigit(tok[i+1]) {
		return 0, false
	}
	return int(tok[i]-'0')*10 + int(tok[i+1]-'0'), true
}

func isLeap(y int) bool { return y%4 == 0 && (y%100 != 0 || y%400 == 0) }

var daysInMonth = [13]int{0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

// parseDateTime validates a date-like (startsWithDate) or time-like token and
// returns its canonical node, or nil if it is not a valid TOML date/time.
func parseDateTime(tok []byte, startsWithDate bool) *Node {
	out := make([]byte, 0, len(tok)+1)
	i := 0
	if startsWithDate {
		if !isDateShape(tok[:min(10, len(tok))]) {
			return nil
		}
		y := int(tok[0]-'0')*1000 + int(tok[1]-'0')*100 + int(tok[2]-'0')*10 + int(tok[3]-'0')
		m, _ := num2(tok, 5)
		d, _ := num2(tok, 8)
		if y < 1 || m < 1 || m > 12 || d < 1 {
			return nil
		}
		dim := daysInMonth[m]
		if m == 2 && isLeap(y) {
			dim = 29
		}
		if d > dim {
			return nil
		}
		out = append(out, tok[:10]...)
		i = 10
		if i == len(tok) {
			return NewScalar(DateLocal, string(out))
		}
		if tok[i] != 'T' && tok[i] != 't' && tok[i] != ' ' {
			return nil
		}
		out = append(out, 'T')
		i++
	}
	// Time: HH:MM:SS[.frac]
	if len(tok)-i < 8 || tok[i+2] != ':' || tok[i+5] != ':' {
		return nil
	}
	hh, ok1 := num2(tok, i)
	mm, ok2 := num2(tok, i+3)
	ss, ok3 := num2(tok, i+6)
	if !ok1 || !ok2 || !ok3 || hh > 23 || mm > 59 || ss > 59 {
		return nil
	}
	out = append(out, tok[i:i+8]...)
	i += 8
	if i < len(tok) && tok[i] == '.' {
		j := i + 1
		for j < len(tok) && isDigit(tok[j]) {
			j++
		}
		if j == i+1 {
			return nil
		}
		end := j
		for end > i+1 && tok[end-1] == '0' {
			end--
		}
		if end > i+1 {
			out = append(out, tok[i:end]...)
		}
		i = j
	}
	if i == len(tok) {
		if startsWithDate {
			return NewScalar(DateTimeLocal, string(out))
		}
		return NewScalar(TimeLocal, string(out))
	}
	if !startsWithDate {
		return nil
	}
	// Offset.
	rest := tok[i:]
	switch {
	case len(rest) == 1 && (rest[0] == 'Z' || rest[0] == 'z'):
		out = append(out, 'Z')
	case len(rest) == 6 && (rest[0] == '+' || rest[0] == '-') && rest[3] == ':':
		oh, ok1 := num2(rest, 1)
		om, ok2 := num2(rest, 4)
		if !ok1 || !ok2 || oh > 23 || om > 59 {
			return nil
		}
		if oh == 0 && om == 0 {
			out = append(out, 'Z')
		} else {
			out = append(out, rest...)
		}
	default:
		return nil
	}
	return NewScalar(DateTime, string(out))
}
