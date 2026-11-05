/**
 * Spiremark: a two-player duelling-card rules engine.
 *
 * Import `cardgame` to get the whole public API:
 *
 * $(UL
 *   $(LI `cardgame.sexpr`  - s-expression reader and printer)
 *   $(LI `cardgame.cards`  - typed card model and effect-language syntax tree)
 *   $(LI `cardgame.parser` - database reader and validator)
 *   $(LI `cardgame.rng`    - the specified xorshift* generator)
 *   $(LI `cardgame.game`   - game state and the event log)
 *   $(LI `cardgame.engine` - chain, priority, turns, combat and player actions)
 *   $(LI `cardgame.report` - DUMP / LEGAL / VAULT / CARD blocks)
 *   $(LI `cardgame.match`  - match-file parsing and the `simulate` entry point)
 * )
 */
module cardgame;

public import cardgame.cards;
public import cardgame.engine;
public import cardgame.game;
public import cardgame.match;
public import cardgame.parser;
public import cardgame.report;
public import cardgame.rng;
public import cardgame.sexpr;
