package cardgame_test

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"cardgame"
	"cardgame/cards"
	"cardgame/engine"
	"cardgame/match"
)

const exampleDB = `
(card TST-001 (name "Bolt") (type rite) (cost 1) (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))
`

// Run a whole match file through the one-call API.
func ExampleRunString() {
	dir, _ := os.MkdirTemp("", "cardgame")
	defer os.RemoveAll(dir)
	db := filepath.Join(dir, "db.spire")
	os.WriteFile(db, []byte(exampleDB), 0o644)

	var out strings.Builder
	cardgame.RunString("CARDS "+db+"\nSEED 1\nOPENING 0\nSTART\nCARD TST-001\n", &out)
	fmt.Print(out.String())
	// Output:
	// 1 GAME-START A
	// 2 SHUFFLE A
	// 3 SHUFFLE B
	// 4 TURN 1 A
	// 5 PHASE dawn
	// 6 EMBER A 1 1
	// 7 EMBER B 0 0
	// 8 PHASE draw
	// 9 PHASE main1
	// CARD BEGIN TST-001
	// name Bolt
	// type rite
	// cost 1
	// tags -
	// keywords swift
	// ability 1 resolve (targets (any)) (damage 2 (t 1))
	// CARD END
	// 10 RESULT pending none
}

// Drive the engine directly, one command at a time.
func ExampleGame_Exec() {
	db, _ := cards.Parse([]byte(exampleDB))
	file, _ := match.ParseFile("CARDS unused\nSEED 1\nOPENING 0\nSHUFFLE off\nHAND A TST-001\nSTART\n")
	game, _ := engine.New(db, file.Setup)

	for i, line := range []string{"A PLAY 1 B", "A PASS", "B PASS", "A PASS"} {
		cmd, err := match.ParseCommand(line)
		if err != nil {
			game.Reject(i+1, "bad-syntax")
			continue
		}
		game.Exec(cmd, i+1)
	}
	game.Finish()
	fmt.Print(string(game.Output()))
	// Output:
	// 1 GAME-START A
	// 2 TURN 1 A
	// 3 PHASE dawn
	// 4 EMBER A 1 1
	// 5 EMBER B 0 0
	// 6 PHASE draw
	// 7 PHASE main1
	// 8 PLAY A ~1 #1 TST-001 B
	// 9 PAY A ember 1
	// 10 PASS A
	// 11 PASS B
	// 12 RESOLVE ~1
	// 13 DAMAGE #1 B 2
	// 14 SPIRE B -2 23
	// 15 SPENT #1 TST-001
	// 16 PASS A
	// 17 RESULT pending none
}
