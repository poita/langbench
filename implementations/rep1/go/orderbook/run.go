package orderbook

import "fmt"

// Run executes a parsed script against a fresh book and returns the
// resulting events as text, one per line.
func (s *Script) Run() ([]byte, error) {
	b, err := NewBook(s.Prices)
	if err != nil {
		return nil, err
	}
	b.Reserve(len(s.Commands))
	for i := range s.Commands {
		if err := b.execRanked(&s.Commands[i]); err != nil {
			return nil, fmt.Errorf("orderbook: command %d: %w", i+1, err)
		}
	}
	return b.Output(), nil
}

// Run parses input (the text protocol: a command count followed by that
// many commands) and returns the events it produces. An empty command list
// yields empty output.
func Run(input []byte) ([]byte, error) {
	s, err := Parse(input)
	if err != nil {
		return nil, err
	}
	return s.Run()
}
