package engine_test

import (
	"fmt"
	"os"

	"github.com/spiremark/cardgame/cards"
	"github.com/spiremark/cardgame/engine"
)

// Set up a match with one rite in A's hand, play it at B's Spire, and let it
// resolve. Events are written to the writer given to New.
func ExampleNew() {
	db, err := cards.Parse(`
(card ZAP-001 (name "Zap") (type rite) (cost 1) (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))`)
	if err != nil {
		panic(err)
	}
	cfg := engine.DefaultConfig()
	cfg.Opening = 0
	cfg.Shuffle = false
	cfg.Hand[engine.A] = []engine.CardCount{{ID: "ZAP-001", Count: 1}}

	g, err := engine.New(cfg, db, os.Stdout)
	if err != nil {
		panic(err)
	}
	play := engine.Action{
		Kind: engine.ActPlay, Player: engine.A, Pos: 1,
		Targets: []engine.TargetRef{{Kind: engine.RefPlayer, Player: engine.B}},
	}
	for _, a := range []engine.Action{
		play,
		{Kind: engine.ActPass, Player: engine.A},
		{Kind: engine.ActPass, Player: engine.B},
	} {
		if err := g.Do(a); err != nil {
			fmt.Println("rejected:", err)
		}
	}
	g.Finish()
	// Output:
	// 1 GAME-START A
	// 2 TURN 1 A
	// 3 PHASE dawn
	// 4 EMBER A 1 1
	// 5 EMBER B 0 0
	// 6 PHASE draw
	// 7 PHASE main1
	// 8 PLAY A ~1 #1 ZAP-001 B
	// 9 PAY A ember 1
	// 10 PASS A
	// 11 PASS B
	// 12 RESOLVE ~1
	// 13 DAMAGE #1 B 2
	// 14 SPIRE B -2 23
	// 15 SPENT #1 ZAP-001
	// 16 RESULT pending none
}
