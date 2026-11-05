package engine

// Error kinds of ERR lines (SPEC 24).
const (
	errBadSyntax          = "bad-syntax"
	errGameOver           = "game-over"
	errNotYourTurn        = "not-your-turn"
	errWrongDecision      = "wrong-decision"
	errNoSuchCard         = "no-such-card"
	errBadTiming          = "bad-timing"
	errBadTargetCount     = "bad-target-count"
	errIllegalTarget      = "illegal-target"
	errCannotAfford       = "cannot-afford"
	errNoSuchObject       = "no-such-object"
	errNoSuchAbility      = "no-such-ability"
	errCostUnpayable      = "cost-unpayable"
	errDuplicateAttacker  = "duplicate-attacker"
	errIllegalAttacker    = "illegal-attacker"
	errMissingAttacker    = "missing-required-attacker"
	errDuplicateBlocker   = "duplicate-blocker"
	errIllegalBlocker     = "illegal-blocker"
	errMissingRequiredBlk = "missing-required-block"
)
