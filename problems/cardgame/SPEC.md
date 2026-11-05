# cardgame — Spiremark, a two-player duelling-card rules engine

Implement the complete rules engine for **Spiremark**, an invented two-player
card game. The program reads a *match file* from stdin: a setup block, then a
script of player actions and inspection directives. It simulates the match
exactly as specified below and writes a deterministic log — one line per rules
event — interleaved with the blocks requested by the inspection directives.

Spiremark is not any existing card game. Every zone, phase, keyword, card and
effect in this document is defined here and nowhere else; where this document
is silent, the behaviour is **not** tested, but an implementation that follows
this document literally will agree with the reference on every test.

Everything observable is integer-valued or a fixed token. There is no
floating-point arithmetic anywhere in the problem, and no player ever makes a
free choice: all choices are either written in the script or decided by a rule
given here.

---

## 1. Contents

1. Contents
2. Architecture and expected size
3. I/O contract
4. Match-file format
5. Card database file
6. Effect language
7. Objects, zones, identity, timestamps
8. Setup
9. Turn structure
10. Priority, the Chain, and settling
11. Playing cards and activating abilities
12. Targeting
13. Triggered abilities
14. Continuous effects and layers
15. Replacement and prevention effects
16. Keywords
17. Damage, destruction and other state changes
18. State checks
19. Combat
20. Win and draw conditions
21. Legal actions
22. Output: event lines
23. Output: inspection blocks
24. Errors
25. Pseudo-random number generator
26. Worked examples
27. Index of card ids

---

## 2. Architecture and expected size

A reasonable implementation has these parts:

| Part | Purpose | Rough share |
| --- | --- | --- |
| S-expression reader | tokenise and parse the card database | 4% |
| Card model + validator | typed cards, abilities, keyword tables | 8% |
| Canonical printer | re-print abilities for the `CARD` directive | 4% |
| Match-file parser | setup directives, script commands | 6% |
| Game state | zones, objects, ids, timestamps, players | 8% |
| Layer engine | continuous effects, derived characteristics | 9% |
| Effect interpreter | the ~30 effect forms, selectors, filters, amounts | 20% |
| Chain + priority | announce, pay, resolve, fizzle, negate | 8% |
| Trigger engine | event queue, collection, ordering, delayed triggers | 9% |
| Combat | attackers, blockers, assignment, damage sub-steps | 7% |
| Legal-action enumerator | canonical action lists | 6% |
| Output / state dump | event lines, dump blocks, errors | 11% |

The intended size is **about 9,000–11,000 lines of C++, Rust, Go or D**. The
reference implementation shipped with this problem is about 3,650 lines of
dense Python (stdlib only); a statically typed language needs roughly three
times that for the same work. The dominating costs are the effect
interpreter, the layer engine and the derived-characteristic plumbing: there
are no shortcuts that collapse those, because the card pool is data, not code.

Performance target: the largest tests run matches of a few hundred turns with
scripts of up to ~60,000 commands. A straightforward implementation that
recomputes derived characteristics on demand is fast enough; recomputing them
inside an inner loop over all objects for every single predicate is not.

---

## 3. I/O contract

**Stdin mode** (see `CONVENTIONS.md`). The entire match file arrives on stdin;
all output goes to stdout; nothing is written anywhere else; there are no
command-line arguments. Exit status is 0 in every case described here,
including every `FATAL` and `ERR` case.

Input and output are UTF-8 text. Input lines are terminated by `\n`; a `\r`
immediately before a `\n` is stripped. Output lines are terminated by `\n`.
Trailing whitespace on a line and trailing newlines at end of output are
ignored by the test runner, but emit none.

The card database is read from the filesystem. The match file names it with a
`CARDS <path>` line; a relative path is resolved against the process's current
working directory, which the runner sets to `problems/cardgame/`. The main
database shipped with this problem is `data/cards.spire`, which almost every
test uses; implementations must not embed its data in the program. A few tests
name another file under `data/` instead: `data/extra.spire` and
`data/lexer.spire` are further valid databases, `data/empty.spire` is a valid
database that defines no cards, the files under `data/bad/` are deliberately
invalid, and a path that does not exist is also possible. All of them are read
by the same reader and validator (section 5).

---

## 4. Match-file format

```
<match-file> ::= { <setup-line> } "START" "\n" { <script-line> }
```

Lines are processed in order. A line whose first non-space character is `#`,
and a line containing only whitespace, is a **comment line**: it is ignored
everywhere (before `START`, after `START`, and between setup lines), but it
still counts when line numbers are reported in `ERR` lines.

Every other line is split into **words** on runs of spaces and tabs; leading
and trailing whitespace is discarded. The first word is the directive or
player word. All keywords in the match file are case-sensitive and written as
shown. Card ids are case-sensitive (upper case, as in the database).

### 4.1 Setup lines

Each line below may appear at most once unless stated otherwise. `CARDS` and
`SEED` are required. The `START` line is required and ends the setup block.

| Line | Meaning | Default |
| --- | --- | --- |
| `CARDS <path>` | path of the card database | required |
| `SEED <n>` | PRNG seed, decimal, 0 ≤ n < 2^64 | required |
| `SPIRE <n>` | starting Spire of both players, 1 ≤ n ≤ 1000000 | 25 |
| `OPENING <n>` | opening hand size, 0 ≤ n ≤ 20 | 5 |
| `MAXCAP <n>` | maximum Ember cap, 1 ≤ n ≤ 100 | 10 |
| `HANDMAX <n>` | hand-size limit enforced at Dusk, 0 ≤ n ≤ 100 | 7 |
| `TURNLIMIT <n>` | draw after this many turns, 1 ≤ n ≤ 100000 | 200 |
| `FIRST A` / `FIRST B` | which player takes turn 1 | `A` |
| `SHUFFLE on` / `SHUFFLE off` | whether vaults are shuffled at setup | `on` |
| `TRACE none\|legal\|state` | automatic block after every action | `none` |
| `CAP A <n>` / `CAP B <n>` | starting Ember cap of that player, 0 ≤ n ≤ 100 | 0 |
| `DECK A <entries>` | cards appended to that player's vault | empty |
| `HAND A <entries>` | cards placed in that player's hand | empty |
| `FIELD A <entries>` | cards placed on the Field under that player | empty |
| `ASH A <entries>` | cards placed in that player's Ash | empty |
| `RIFT A <entries>` | cards placed in that player's Rift | empty |

`DECK`, `HAND`, `FIELD`, `ASH` and `RIFT` may each appear any number of times
for each player; their entries are appended in the order the lines appear.
`<entries>` is one or more space-separated entries, each either `<cardid>` or
`<cardid>*<count>` with `1 <= count <= 1000`, meaning that many copies.

`CAP A` and `CAP B` count as separate single-use lines, and `FIRST`, `SHUFFLE`
and `TRACE` are each one single-use line whatever their argument. `START` takes
no argument. A number in a setup line is a non-empty run of decimal digits
with no sign (leading zeros are allowed) and must fall in the stated range;
anything else is `bad-setup`. The `<cardid>` part of an entry is any non-empty
word without a `*`; whether the database defines it is checked in step 3 of
section 8, which reports `unknown-card`, not `bad-setup`.

### 4.2 Script lines

```
<script-line> ::= <player> " " <action> | <directive>
<player>      ::= "A" | "B"
<action>      ::= "PASS"
                | "CONCEDE"
                | "PLAY" " " <pos> { " " <target> }
                | "ACT" " " <objref> " " <index> { " " <target> }
                | "ATTACK" { " " <objref> }
                | "BLOCK" { " " <objref> ":" <objref> }
<directive>   ::= "DUMP" | "LEGAL" | "VAULT" | "CARD" " " <cardid>
<pos>         ::= decimal integer, 1-based hand position
<index>       ::= decimal integer, 1-based ability number
<objref>      ::= "#" decimal integer            (an object id)
<target>      ::= "A" | "B" | "#" decimal | "~" decimal
```

Decimal integers in the script have no sign and no leading `+`; leading zeros
are allowed and ignored (`#007` is object 7). Values must fit in 64 bits.

An **action** line is only accepted from the player the engine is waiting for
(section 10). Directives never change the game; they print a block
(section 23) at the point they appear.

`TRACE legal` or `TRACE state` makes the engine print, after every action line
that was *accepted*, the block that `LEGAL` or `DUMP` would have printed at
that moment — that is, after the action has been processed and the engine has
run forward to the next decision point (or the match has ended). Rejected
actions (those that produce an `ERR` line) print no trace block, and neither do
directive lines.

---

## 5. Card database file

The database is a text file of s-expressions, UTF-8, no byte-order mark.

### 5.1 Lexical structure

```
token ::= "(" | ")" | <string> | <atom>
```

* Whitespace (space, tab, CR, LF, FF, VT) separates tokens and is otherwise
  insignificant.
* `;` outside a string starts a comment that runs to the end of the line.
* `<string>` is `"` followed by any characters other than `"` or a newline,
  followed by `"`. There are no escapes.
* `<atom>` is a maximal run of one or more characters that are not
  whitespace, `(`, `)`, `;` or `"`.
* An atom that matches `-?[0-9]+` is an **integer** atom; its value must fit
  in a signed 64-bit integer. Every other atom is a **symbol**. Symbols are
  case-sensitive.

### 5.2 Grammar

```
<file>    ::= { <card> }
<card>    ::= "(" "card" <cardid> { <clause> } ")"
<cardid>  ::= symbol matching [A-Z]{3} "-" [0-9]{3}
<clause>  ::= "(" "name" <string> ")"
            | "(" "type" ("unit"|"rite"|"relic") ")"
            | "(" "cost" <int> ")"
            | "(" "body" <int> <int> ")"
            | "(" "tags" { <symbol> } ")"
            | "(" "keywords" { <kwspec> } ")"
            | "(" "text" <string> ")"
            | "(" "resolve" { <abil-part> } ")"
            | "(" "on" <event> { <abil-part> } ")"
            | "(" "act" { <abil-part> } ")"
            | "(" "aura" { <static> } ")"
<kwspec>  ::= <keyword> | "(" "plating" <int> ")"
<abil-part> ::= "(" "cost" { <costitem> } ")"
            | "(" "targets" { <tspec> } ")"
            | <effect>
```

Required and forbidden clauses:

* exactly one `name`, one `type`, one `cost`; `cost` ≥ 0;
* `body` exactly once on a `unit`, never otherwise; both values ≥ 0;
* `tags`, `keywords`, `text` at most once each;
* exactly one `resolve` on a `rite`, never otherwise;
* `on`, `act`, `aura` any number of times, in any order, on any type;
* inside an ability, `cost` appears only in `act` (exactly once) and
  `targets` at most once; both must precede every effect; at least one effect
  must be present in `resolve`, `on` and `act`; at least one static in `aura`.

**Keyword legality.** `swift` may appear only on a `rite`. The keywords
`vanguard`, `vigil`, `riposte`, `pierce`, `ghostwalk`, `skyhook`, `venom`,
`siphon`, `plating`, `provoke`, `spectral`, `tenacity`, `siegework`,
`shackled` and `relentless` may appear only on a `unit`. A `relic` has no
printed keywords.

### 5.3 Ability numbering

A card's abilities are numbered from 1 in this order:

1. the `resolve` clause, if any;
2. the `on` clauses, in file order;
3. the `act` clauses, in file order;
4. the `aura` clauses, in file order.

This single numbering is used by the `CARD` directive, by `ACT` commands, by
`ACTIVATE` and `TRIGGER` event lines and by `LEGAL` output.

### 5.4 Validation

If the file cannot be read, does not tokenise, does not match the grammar,
violates a rule in 5.2, declares two cards with the same id, names in a
`summon`/`conjure` effect a card id that the file does not define, or names in
a `summon` effect a card whose type is `rite`, the program prints exactly one
line

```
FATAL bad-database
```

and nothing else. Semantic nonsense that the grammar admits (an `on` event
that no card could ever satisfy, say) is not an error.

`data/cards.spire` is valid, as are `data/extra.spire`, `data/lexer.spire` and
the card-less `data/empty.spire`; the `bad-database` path is reached when a
match file names a `CARDS` path that cannot be read or that holds an invalid
database, such as one of the files under `data/bad/`.

---

## 6. Effect language

This section defines the meaning of every form. "The ability" means the
ability being resolved or evaluated; "the source" is the object the ability is
printed on; "the controller" is the ability's controller (section 7.4).

### 6.1 Comparators

`<cmp>` is one of `le lt eq ge gt ne`, meaning `<=`, `<`, `==`, `>=`, `>`,
`!=` of the left value against the right value.

### 6.2 Printed, base and current characteristics

Every object has three sets of characteristics.

**Printed** characteristics are the card's: edge, core, keywords, cost, type,
tags, name. A card that is not a `unit` has no `body` clause; its printed edge
and printed core are both **0**.

**Base** characteristics are used by filters (6.5) and by nothing else:

* base edge = printed edge + number of charge counters
* base core = printed core + number of charge counters
* base keywords = printed keywords
* base cost, type, tags, name = printed values

**Current** characteristics are what the game rules use. They are derived from
the *printed* edge, core and keywords by the layer system (section 14), which
applies charge counters at layer 5 — after `setbody` and `modify`, before
`swapstats`.

> **Filters always test base characteristics.** Every predicate in section 6.5
> that inspects edge, core, keywords, cost, type or tags uses base values.
> This makes the layer system non-circular: nothing a continuous effect
> produces can change which objects a continuous effect applies to. Rules that
> are not filters — `spectral` targeting protection, `venom`, `plating`,
> `pierce`, blocking restrictions, combat, state checks — always use **current**
> characteristics.

Only objects on the Field have continuous effects, charge counters and Field
state. For an object in any other zone: base and current edge/core are the
printed values, the current keywords are the printed keywords, its abilities
are never removed by `strip`, and its controller is the controller it had when
it last left the Field (its owner if it has never been on the Field).

### 6.3 Selectors

A selector denotes zero or more objects.

| Form | Meaning |
| --- | --- |
| `self` | the source object, wherever it now is |
| `it` | the trigger subject (section 13.2); nothing for non-triggered abilities |
| `that` | the object bound by the innermost enclosing `each` |
| `(t <n>)` | the ability's n-th target; nothing when that target is a player or was removed as illegal |
| `(units <scope> {<filter>})` | units on the Field matching all filters |
| `(relics <scope> {<filter>})` | relics on the Field matching all filters |
| `(cards <zone> <scope> {<filter>})` | cards in that zone matching all filters, `<zone>` one of `hand ash vault rift` |
| `(random-unit <scope> {<filter>})` | one unit drawn with the PRNG from the units `(units <scope> ...)` would give (section 25); nothing if there are none |

`<scope>` is `yours`, `theirs` or `all`. For Field objects it compares the
object's **current controller** with the ability's controller; for `cards`
it compares the card's **owner** with the ability's controller.

Where a selector yields several objects, the effect applies to all of them,
processed in **canonical object order**: ascending `(timestamp, oid)`
(section 7.3).

**Zone requirements.** An effect that needs its object to be on the Field
silently skips objects that are not: `destroy`, `sacrifice`, `bounce`,
`ready`, `exhaust`, `doom`, `ward`, `counters`, `control`, damage dealt to an
object, and the affected list of a discrete continuous-effect record. An
effect that needs its card to be in an Ash — `reanimate`, `recall` — skips
cards that are not. `exile` works from any zone. Damage dealt to a relic has
no effect at all (relics have no wounds): the damage is not dealt, no event is
emitted and no trigger is collected.

### 6.4 Player selectors

| Form | Meaning |
| --- | --- |
| `you` | the ability's controller |
| `foe` | the opponent of the ability's controller |
| `both` | both players, A before B |
| `(t <n>)` | the n-th target, which must be a player; nothing otherwise |
| `(owner-of <sel>)` | the owners of the objects `<sel>` yields, de-duplicated, A before B; if `<sel>` is `(t n)` and target n is a player, that player |

### 6.4.1 Damage selectors

A `<dsel>` is a selector that may yield objects, players, or both. It is read
as a player selector (6.4) when it is `you`, `foe`, `both` or
`(owner-of <sel>)`; as an object selector (6.3) for every other form; and, for
`(t <n>)`, as whichever the n-th target actually is — a player when the target
is a player, that object when it is an object, and nothing when the target was
removed. `<dsel>` appears only as the second argument of `damage`.

Damage is dealt to the yielded things in ascending target-key order (12.4),
players therefore before objects.

### 6.5 Filters

All filters of a selector must hold. `<filter>` is one of:

| Form | True when |
| --- | --- |
| `(kw <keyword>)` | the object's base keywords include that keyword (any `plating` value matches `plating`) |
| `(no-kw <keyword>)` | they do not |
| `(tag <symbol>)` | the card's tags include that symbol |
| `(type <t>)` | the card's type is `unit`, `rite` or `relic` |
| `(cost <cmp> <int>)` | printed cost compares so |
| `(edge <cmp> <int>)` | base edge compares so |
| `(core <cmp> <int>)` | base core compares so |
| `(wounded)` | the object is on the Field and has at least one wound |
| `(ready)` | the object is on the Field and is ready |
| `(exhausted)` | the object is on the Field and is exhausted |
| `(settling)` | the object is on the Field and is Settling (16.1) |
| `(attacking)` | the object is an attacking unit |
| `(blocking)` | the object is a blocking unit |
| `(mine)` | current controller (Field) or owner (elsewhere) is the ability's controller |
| `(enemy)` | it is the opponent |
| `(other)` | the object is not the source object |
| `(not <filter>)` | the inner filter is false |

### 6.6 Amounts

`<amt>` evaluates to a signed integer.

| Form | Value |
| --- | --- |
| `<int>` | itself |
| `(count <sel>)` | number of objects `<sel>` yields |
| `(hand <psel>)` | total hand size over the players `<psel>` yields |
| `(ash <psel>)` | total Ash size |
| `(vault <psel>)` | total Vault size |
| `(edge <sel>)` | sum of current edge over the objects |
| `(core <sel>)` | sum of current core |
| `(wounds <sel>)` | sum of wounds |

Inside an `aura` static (6.11) `(edge <sel>)` and `(core <sel>)` sum **base**
edge and core instead, so that derivation stays non-circular. Everywhere else
they use current values. No card in `data/cards.spire` uses them in an aura;
`data/extra.spire` does.

### 6.7 Conditions

| Form | True when |
| --- | --- |
| `(count <sel> <cmp> <int>)` | the count compares so |
| `(spire <psel> <cmp> <int>)` | the summed Spire compares so |
| `(hand <psel> <cmp> <int>)` | the summed hand size compares so |
| `(ash <psel> <cmp> <int>)` | the summed Ash size compares so |
| `(vault <psel> <cmp> <int>)` | the summed Vault size compares so |
| `(ember <psel> <cmp> <int>)` | the summed Ember compares so |
| `(myturn)` | the active player is the ability's controller |
| `(and {<cond>})` | all hold (vacuously true when empty) |
| `(or {<cond>})` | at least one holds (false when empty) |
| `(not <cond>)` | the inner condition is false |

### 6.8 Effects

Effects of an ability are executed in written order, each completely, before
the next begins. No state check runs between them (section 18).

| Form | Meaning |
| --- | --- |
| `(damage <amt> <dsel>)` | deal that much damage from the source to each thing the selector yields (17.1), the amount evaluated once before any of it is dealt. No effect when the amount is ≤ 0. |
| `(destroy <sel>)` | destroy each object on the Field (17.3) |
| `(sacrifice <sel>)` | sacrifice each object on the Field (17.4) |
| `(exile <sel>)` | move each object to its owner's Rift (17.5) |
| `(bounce <sel>)` | move each Field object to its owner's hand (17.6) |
| `(draw <amt> <psel>)` | each player draws that many cards (17.7) |
| `(discard <amt> <psel>)` | each player discards that many cards from hand position 1 (17.8) |
| `(mill <amt> <psel>)` | each player moves that many cards from the top of their Vault to their Ash (17.9) |
| `(spire <amt> <psel>)` | each player's Spire changes by that much (17.10) |
| `(ember <amt> <psel>)` | each player gains that much Ember (17.11) |
| `(cap <amt> <psel>)` | each player's cap becomes `min(cap + amt, MAXCAP)` (17.12); nothing when ≤ 0 |
| `(modify <amt> <amt> <sel>)` | create a turn-duration layer-4 effect giving the matched objects those edge and core deltas |
| `(setbody <amt> <amt> <sel>)` | create a turn-duration layer-3 effect setting edge and core |
| `(swapstats <sel>)` | create a turn-duration layer-6 effect swapping edge and core |
| `(grant <kwspec> <sel>)` | create a turn-duration layer-2 effect adding that keyword |
| `(strip <sel>)` | create a turn-duration layer-2 effect removing all keywords and all abilities |
| `(control <sel>)` | create a turn-duration layer-1 effect giving control to the ability's controller (17.13) |
| `(counters <amt> <sel>)` | add that many charge counters (negative removes, floored at zero) (17.14) |
| `(ready <sel>)` | each Field object becomes ready (17.15) |
| `(exhaust <sel>)` | each Field object becomes exhausted (17.15) |
| `(doom <sel>)` | mark each Field unit Doomed (17.16) |
| `(ward <amt> <sel>)` | add that many prevention points to each Field object's ward pool (15.2); nothing when ≤ 0 |
| `(shield <amt> <psel>)` | add that many prevention points to each player's shield pool (15.2); nothing when ≤ 0 |
| `(summon <cardid> <amt> <psel>)` | create that many new objects of that card on each player's Field (17.17) |
| `(conjure <cardid> <amt> <psel>)` | create that many new objects of that card in each player's hand (17.17) |
| `(reanimate <sel>)` | move each matched Ash card that is a unit to the Field under the ability's controller (17.18) |
| `(recall <sel>)` | move each matched Ash card to its owner's hand (17.19) |
| `(negate <sel>)` | remove each matched Chain entry from the Chain (17.20). `<sel>` must be `(t n)`. |
| `(dig <int> "(" {<filter>} ")" <psel>)` | look at the top cards and take the first match (17.21) |
| `(delay <when> {<effect>})` | register a delayed trigger (13.5); `<when>` is `turn-end`, `end-of-combat` or `your-next-turn-start` |
| `(if <cond> "(" {<effect>} ")")` | execute the effects when the condition holds |
| `(if <cond> "(" {<effect>} ")" "(" {<effect>} ")")` | …otherwise execute the second list |
| `(each <sel> {<effect>})` | for each matched object in canonical order, bind `that` and execute the effects (6.9) |
| `(repeat <amt> {<effect>})` | execute the effects that many times (nothing when ≤ 0) |
| `(nothing)` | do nothing |

Every effect whose first argument is a count — `damage`, `draw`, `discard`,
`mill`, `ember`, `cap`, `ward`, `shield`, `summon`, `conjure`, `repeat` — does
nothing at all when that amount evaluates to 0 or less. (`spire`, `counters`
and `modify`/`setbody` take signed amounts and are not counts.)

### 6.9 `each`

`(each <sel> ...)` evaluates `<sel>` once, at the moment the `each` begins,
and fixes the resulting list in canonical object order. For every element in
turn: if the object is no longer in the zone it occupied when the list was
built, the iteration is skipped entirely; otherwise `that` is bound to it and
the body runs. `each` may nest; `that` always refers to the innermost `each`.

### 6.10 Activated-ability costs

`<costitem>` is one of:

| Form | Payment |
| --- | --- |
| `(ember <int>)` | pay that much Ember |
| `(spire <int>)` | lose that much Spire — a Spire change of `-<int>` by 17.10, including its `spire-loss` triggers; this is not damage |
| `(discard <int>)` | discard that many cards from hand position 1 (17.8) |
| `(exhaust)` | the source becomes exhausted (17.15); requires it to be on the Field, ready, and not Settling unless it has `vanguard` (16.1) |
| `(sacself)` | the source is sacrificed (17.4); requires it to be on the Field |
| `(counters <int>)` | remove that many charge counters from the source (17.14); requires at least that many |
| `(once)` | no payment; the ability may be used at most once per turn by this object |

Every cost item is checked for payability **before** any is paid; see 11.3.
Paying an item emits its `PAY` line first, if it has one, and then the events
of the state change it performs: `(ember n)` emits `PAY <P> ember <n>` and
nothing else; `(spire n)` emits `PAY <P> spire <n>` and then the `SPIRE` line
of 17.10. Both `PAY` lines are emitted only when `n > 0`. The other items emit
no `PAY` line, only the events of 17.8, 17.15, 17.4 and 17.14; `(once)` emits
nothing.

### 6.11 Aura statics

`<static>` is one of:

| Form | Meaning |
| --- | --- |
| `(modify <amt> <amt> <sel>)` | layer-4 effect on whatever `<sel>` matches, re-evaluated continuously |
| `(setbody <amt> <amt> <sel>)` | layer-3 effect, likewise |
| `(swapstats <sel>)` | layer-6 effect, likewise |
| `(grant <kwspec> <sel>)` | layer-2 effect, likewise |
| `(cheaper <int> {<cardfilter>})` | reduces by `<int>` the Ember cost of cards played by the source's controller that match every `<cardfilter>` |
| `(when <cond> {<static>})` | the inner statics apply only while the condition holds |

`<cardfilter>` is `(type <t>)`, `(tag <symbol>)` or `(cost <cmp> <int>)`,
tested against the printed characteristics of the card being played.

An aura's selector, amounts and condition are **re-evaluated every time
characteristics are derived**, so an aura tracks the board. A `(when …)`
whose condition is false contributes nothing.

Every `aura` clause in the databases shipped under `data/` holds exactly one static, possibly
wrapped in one `(when …)`; the `DUMP` line of an aura record (23.1) describes
that static. The controller of an aura record — the player its `yours` and
`theirs` scopes, its `(mine)`/`(enemy)` filters, its `(myturn)` condition and
its `cheaper` reduction refer to — is the **current controller of its source**,
so taking control of an aura's source turns the aura around.

---

## 7. Objects, zones, identity, timestamps

### 7.1 Players

The two players are `A` and `B`. Each has: a **Spire** total (integer, may go
negative), an **Ember** pool and an **Ember cap** (non-negative integers), a
**shield pool** (non-negative), and five private zones.

### 7.2 Zones

| Zone | Ordering | Notes |
| --- | --- | --- |
| Vault | position 1 is the top | the draw pile |
| Hand | positions 1…n in order | cards are appended when added |
| Field | see 7.3 | units and relics in play |
| Ash | position 1 is the oldest | the discard pile; cards are appended |
| Rift | position 1 is the oldest | the removed-from-play pile |

The **Chain** is a single shared zone, a stack of entries (section 10).

Zones are per-player and are indexed by **owner**. A card always returns to
its owner's zones; only the Field tracks a separate controller.

### 7.3 Object identity, oids and timestamps

Every card instance in the match is an **object** with a permanent **oid**, a
positive integer, printed as `#7`. Oids are assigned during setup
(section 8) and to newly created objects as they are created, from a counter
that starts at 1 and only increases.

A global **timestamp counter** starts at 1. A fresh timestamp is taken from it
(and the counter incremented) when:

* an object enters the Field;
* a continuous-effect record is created (including an aura record);
* a delayed trigger is created.

An object's timestamp is the one it received when it last entered the Field,
or 0 if it has never been on the Field. It keeps that value after leaving.

**Canonical object order** is ascending `(timestamp, oid)`. It orders every
list of objects this document asks to be ordered, in every zone.

### 7.4 Owner and controller

An object's **owner** never changes. Its **base controller** is set when it
enters the Field: the player who played it, the controller of the ability that
put it there, or the player named by a setup `FIELD` line. Its **current
controller** is the base controller unless a layer-1 `control` effect applies
(section 14).

An **ability's controller** is: for a played card, the player who played it;
for an activated ability, the player who activated it; for a triggered
ability, the current controller of its source at the moment the trigger was
collected; for a delayed trigger, the controller of the ability that created
it. The ability's controller is fixed when the entry is created and never
changes afterwards.

### 7.5 Per-object state on the Field

While on the Field an object has: `ready`/`exhausted`; a **wound** count
(≥ 0); a **charge counter** count (≥ 0); a **ward pool** (≥ 0); a **Doomed**
flag; a **since** turn number (16.1); combat status (`attacking`, `blocking`,
the list of blockers of an attacker, the attacker a blocker blocks, and a
`blocked` flag); a **tenacity used** flag; and a set of `(once)` ability
indices already used this turn.

All of this is discarded when the object leaves the Field; an object that
enters the Field again starts with wounds 0, counters 0, ward 0, not Doomed,
ready, no combat status, tenacity unused, no `(once)` usage, and `since` set
to the current turn number.

**Removal from combat.** Whenever a unit leaves the Field (by any means), and
whenever it is removed from combat by a control change (17.13), the other
objects' combat status is kept consistent before anything else happens:

* if the unit was blocking an attacker, it is removed from that attacker's
  blocker list (the attacker's `blocked` flag is unchanged);
* if the unit was attacking, every unit blocking it stops blocking: its
  `blocking` status and blocked attacker are cleared, so it is no longer in
  combat (it shows `-` instead of `blocking` in `DUMP`, no longer matches a
  `(blocking)` filter, deals and receives no combat damage, and does not count
  as in combat for 19.7).

---

## 8. Setup

1. Parse the match file's setup block. On any violation of section 4.1 — a
   missing `CARDS`, `SEED` or `START` line, a duplicate single-use line, an
   unknown setup word, a malformed or out-of-range number, a bad `<entries>`
   word — print exactly `FATAL bad-setup` and stop.
2. Read and validate the card database (section 5.4); on failure print
   `FATAL bad-database` and stop.
3. If any `DECK`/`HAND`/`FIELD`/`ASH`/`RIFT` entry names a card id the
   database does not define, print `FATAL unknown-card` and stop.
4. Both players start with Spire = `SPIRE`, Ember = 0, cap = the `CAP` value
   for that player (default 0), empty zones, shield pool 0.
5. Assign oids. Process player A completely, then player B. Within a player,
   process the zones in the order `DECK`, `HAND`, `FIELD`, `ASH`, `RIFT`,
   and within a zone the entries in the order the setup lines gave them
   (expanding `*n` into n consecutive copies). Each card instance takes the
   next oid and is placed at the end of that zone.
6. Put the objects placed by `FIELD` lines on the Field, one at a time in
   ascending oid order (so A's objects before B's): each takes a Field
   timestamp, then its aura records are created and take theirs (14.2). Their
   base controller is the player named on the line; their owner is the same
   player; their `since` is 0, so they are not Settling on turn 1. Entering
   the Field this way fires **no** triggers.
7. Seed the PRNG (section 25). If `SHUFFLE on`, shuffle player A's Vault,
   emit `SHUFFLE A`, then shuffle player B's Vault and emit `SHUFFLE B`.
   With `SHUFFLE off` the Vault keeps the order the `DECK` lines gave and no
   `SHUFFLE` event is emitted. (The `GAME-START` event precedes both; see the
   ordering below.)
8. Opening hands: the first player draws `OPENING` cards, then the other
   player draws `OPENING` cards, using the normal draw procedure (17.7) —
   including `DRAW-EMPTY` and the resulting pending loss — but firing no
   triggers. The two opening draws are separate effects, so a `DRAW-EMPTY`
   stops only that player's remaining opening draws: each player emits at most
   one `DRAW-EMPTY`, and both may do so.
9. Run `settle` (10.5) once. This ends the match immediately if an opening
   draw emptied a Vault.
10. Begin turn 1 with the first player active.

The events emitted by setup, in order, are: `GAME-START <first>`, then the
`SHUFFLE` events, then the `DRAW`/`DRAW-EMPTY` events of the opening hands,
then whatever `settle` produces, then `TURN 1 <first>`.

---

## 9. Turn structure

Turns are numbered from 1. The **active player** is the first player on odd
turns and the other player on even turns. A turn consists of these phases and
steps, in order. Entering each one emits `PHASE <name>`.

| # | name | priority round? |
| --- | --- | --- |
| 1 | `dawn` | no |
| 2 | `draw` | no |
| 3 | `main1` | yes |
| 4 | `clash-attack` | after the declaration |
| 5 | `clash-block` | after the declaration |
| 6 | `clash-riposte` | yes (step may be skipped) |
| 7 | `clash-damage` | yes |
| 8 | `clash-end` | yes |
| 9 | `main2` | yes |
| 10 | `dusk-trigger` | yes |
| 11 | `dusk-discard` | no |
| 12 | `dusk-cleanup` | no |

A step without a priority round performs its turn-based actions and then runs
`drain` (10.6): the Chain is emptied automatically, with no player able to
respond. A step with a priority round performs its turn-based actions and then
runs a priority round (10.4).

### 9.1 `dawn`

In order:

1. The active player's cap becomes `min(cap + 1, MAXCAP)`.
2. Each player's Ember is **set** to that player's cap: first A, then B,
   each emitting `EMBER <player> <ember> <cap>`. (Both events are always
   emitted, in that order, even when nothing changed.)
3. Every object the **active player** currently controls that is exhausted
   becomes ready, in canonical object order, each emitting `READY #oid`.
4. For every object on the Field (both players), clear the `tenacity used`
   flag and the set of used `(once)` ability indices.
5. Collect `turn-start` triggers, and `your-turn-start` triggers of objects
   whose controller is the active player. Also fire delayed triggers
   registered for `your-next-turn-start` whose controller is the active
   player.
6. `drain`.

### 9.2 `draw`

If the turn number is 1 and the active player is the first player, nothing
happens. Otherwise the active player draws one card (17.7). Then `drain`.

### 9.3 `main1`, `main2`

No turn-based actions. A priority round.

### 9.4 The clash phase

Steps 4–8. See section 19. If the active player declares no attackers, the
clash phase ends immediately at the end of step 4 and steps 5–8 are skipped
entirely (no `PHASE` events for them, no `end-of-combat` triggers).

### 9.5 `dusk-trigger`

Collect `turn-end` triggers from every Field object, and `your-turn-end`
triggers of objects whose controller is the active player. Fire every delayed
trigger registered for `turn-end`. Then a priority round.

### 9.6 `dusk-discard`

While the active player's hand size exceeds `HANDMAX`, discard the card at
hand position 1 (17.8). Then `drain`.

### 9.7 `dusk-cleanup`

In order, with no events emitted:

1. Remove all wounds from every object.
2. Clear the Doomed flag of every object.
3. Set every ward pool and both shield pools to 0.
4. End every turn-duration continuous-effect record (section 14), and for
   each object that a layer-1 `control` record applied to, set `since` to the
   current turn number.
5. Discard every `turn-end` and `end-of-combat` delayed trigger that has not
   fired. A `your-next-turn-start` delayed trigger is kept until it fires.

Nothing in this step is itself a trigger event. Like every other step without a
priority round, it then runs `drain` (10.6), so a unit left with current core
≤ its wounds once the turn-duration records end is destroyed here, and the
`dies` triggers that follow resolve here too.

### 9.8 Turn advance

After `dusk-cleanup`, the turn number increases by 1 and the active player
changes. If the new turn number exceeds `TURNLIMIT`, the match ends in a draw
with reason `turn-limit` (section 20) instead of beginning. The increment
happens first, so a `DUMP` after that draw reports
`turn <TURNLIMIT+1> active <the player who would have been active>` and the
phase `dusk-cleanup`.

---

## 10. Priority, the Chain, and settling

### 10.1 The Chain

The Chain is a stack of **entries**. Each entry has a unique **cid**, a
positive integer printed as `~3`, assigned from a counter that starts at 1 and
only increases. An entry has a kind (`rite`, `unit`, `relic`, `ability`,
`trigger`), a controller, a source object, an ability index (0 for a played
card), and a list of targets.

Entries resolve from the top. The top entry is the one most recently pushed,
except where section 13.3 pushes a batch of triggers in a specified order.

### 10.2 Decision points

The engine always runs forward until it needs input, then stops at a
**decision point**, described by the waiting player and a kind:

* `priority` — the player may `PASS`, `PLAY`, `ACT` or `CONCEDE`;
* `attackers` — the player must issue `ATTACK` (or `CONCEDE`);
* `blockers` — the player must issue `BLOCK` (or `CONCEDE`).

Before stopping at any decision point — including an `attackers` or
`blockers` decision — the engine runs `settle` (10.5), so a match that has
been decided ends before any further input is read.

An accepted action is processed and the engine runs forward again to the next
decision point before reading the next script line. A `DUMP`, `LEGAL` or
`VAULT` directive, and a `TRACE` block, therefore always describe a state in
which the engine is waiting for input (or in which the match has ended). When
the script ends, the engine stops: the remaining turns are *not* played out.

### 10.3 Pass handling

A priority round keeps a **pass counter**, starting at 0, and a priority
holder. `PASS` increments the counter, then:

* if the counter is 1, the other player becomes the holder;
* if the counter is 2 and the Chain is **not** empty, the counter is reset to
  0 and the top entry resolves (section 11.6), after which `settle` runs and
  the active player becomes the holder;
* if the counter is 2 and the Chain **is** empty, the priority round ends and
  the step ends.

Any accepted action other than `PASS` **resets the pass counter to 0** and
leaves the acting player holding priority. So a player who plays a card in
response to the opponent's card still has to pass, and the opponent still gets
priority again, before anything resolves.

### 10.4 Priority round

```
pass counter := 0
settle()
holder := active player
loop:
    wait for an action from the holder
    PASS            -> 10.3
    PLAY / ACT      -> perform it; pass counter := 0; holder := the actor;
                       then settle()
```

Whenever `settle` reports that it did something (a state check acted or
triggers were pushed), the pass counter is reset to 0 and the holder becomes
the active player. This applies to the `settle` after a `PLAY`/`ACT` as well:
playing a rite that some object listens for therefore hands priority back to
the active player.

### 10.5 `settle`

```
settle():
    acted := false
    loop:
        a := run the state checks once (section 18)     # may end the match
        b := push the collected triggers, if any (13.3)
        acted := acted or a or b
        exit when not a and not b
    return acted
```

The trigger push reports that it did something whenever the pending list was
non-empty, even when every trigger in the batch was dropped by 13.3 step 2.

### 10.6 `drain`

```
drain():
    loop:
        settle()
        exit when the Chain is empty
        resolve the top entry (11.6)
```

Used by the steps without a priority round. Note that `settle` ends the match
as soon as a player has lost, which stops everything.

---

## 11. Playing cards and activating abilities

### 11.1 Timing

A player may play a card or activate an ability only at a `priority` decision
point at which they are the holder. In addition:

* a `unit` or `relic` card, and a `rite` without `swift`, may be played only
  when the player is the active player, the current phase is `main1` or
  `main2`, and the Chain is empty;
* a `rite` with `swift` may be played whenever the player holds priority;
* an activated ability may be used whenever its controller holds priority and
  the source is on the Field under their control.

### 11.2 Playing a card — procedure

1. Check 11.1.
2. Take the card from the player's hand and make it a new Chain entry with a
   fresh cid: kind `rite`, `unit` or `relic` according to its type, controller
   the player, source the card object, ability index 0.
3. Assign the targets listed on the command to the card's `resolve` ability's
   `targets` clause, if it has one, and check their legality (section 12).
   A `unit` or `relic` never takes targets.
4. Compute the Ember cost: printed cost, minus the sum of the `<int>` of every
   active `cheaper` record controlled by the player whose card filters all
   match the card, floored at 0. Check the player has at least that much
   Ember.
5. Emit `PLAY <player> ~<cid> #<oid> <cardid>` followed by the rendered
   targets, separated by single spaces.
6. Pay the Ember: subtract it and, if it is more than 0, emit
   `PAY <player> ember <n>`.
7. If the card is a `rite`, collect `you-play-rite` triggers of objects
   controlled by the player and `enemy-plays-rite` triggers of objects
   controlled by the opponent. (Units and relics collect nothing here.)

If any check in steps 1–4 fails, nothing at all happens: the card stays in
hand, no Ember is paid, and an `ERR` line is emitted (section 24).

### 11.3 Activating an ability — procedure

1. Check 11.1, that the object is on the Field under the actor's control, and
   that the given index names an `act` ability of its card that is not removed
   by `strip`.
2. Make a new Chain entry with a fresh cid: kind `ability`, controller the
   actor, source the object, the given ability index.
3. Assign and check targets (section 12).
4. Check that every cost item is payable:
   * `(ember n)` — the player's Ember is at least `n`;
   * `(spire n)` — always payable, even when it brings the player to 0 or
     below (which loses the match at the next state check);
   * `(discard n)` — the player's hand holds at least `n` cards;
   * `(exhaust)` — the source is on the Field, ready, and not Settling or has
     `vanguard`;
   * `(sacself)` — the source is on the Field;
   * `(counters n)` — the source has at least `n` charge counters;
   * `(once)` — this ability index of this object has not been used this turn.
5. Emit `ACTIVATE <player> ~<cid> #<oid> <index>` and the rendered targets.
6. Pay the cost items in written order, emitting their events (section 22).
   `(once)` marks the index used.

If a check fails nothing happens and an `ERR` line is emitted.

### 11.4 Where the entry goes

Nothing resolves immediately. After step 7 / step 6 the player retains
priority.

### 11.5 Negated entries

`negate` (17.20) removes an entry from the Chain. A `rite`, `unit` or `relic`
entry's card goes to its owner's Ash; an `ability` or `trigger` entry simply
ceases to exist. A negated entry never resolves and never fizzles.

### 11.6 Resolving an entry

1. Emit `RESOLVE ~<cid>`.
2. Re-check every target for legality (section 12.3). Each illegal target
   becomes **removed**: selectors and amounts that refer to it yield nothing
   and 0.
3. If the entry has at least one target and **all** of them are removed, the
   entry **fizzles**: emit `FIZZLE ~<cid>`, skip step 4, and go to step 5.
4. Execute the entry's effects:
   * kind `rite` — the card's `resolve` effects;
   * kind `unit` or `relic` — the card enters the Field (17.17 step 3);
   * kind `ability` or `trigger` — the named ability's effects, or, for an
     entry from a delayed trigger (ability index 0), that trigger's stored
     effect list. In a delayed trigger's effects `it` yields nothing and
     `self` yields the stored source object.
5. Remove the entry from the Chain. For kind `rite`, move the card to its
   owner's Ash and emit `SPENT #<oid> <cardid>`. For `unit` and `relic` the
   card has already left the Chain for the Field (or, when fizzled — which
   cannot happen, as they have no targets — to Ash). For `ability` and
   `trigger` nothing further happens.

---

## 12. Targeting

### 12.1 Target specifications

A `targets` clause lists one or more `<tspec>`s. The command (or the automatic
choice of 13.4) supplies exactly that many targets, in order.

| `<tspec>` | A legal target is |
| --- | --- |
| `(unit {<filter>})` | a unit on the Field matching all filters |
| `(relic {<filter>})` | a relic on the Field matching all filters |
| `(any {<filter>})` | a player, or a unit on the Field matching all filters |
| `(player)` | a player |
| `(chained)` | a Chain entry other than the entry being announced |
| `(ashcard {<filter>})` | a card in a player's Ash matching all filters |

### 12.2 Additional legality rules

* The **spectral rule**: a unit on the Field whose *current* keywords include
  `spectral` is not a legal target for an ability whose controller is not that
  unit's current controller. It never protects a relic or an Ash card.
* All of an ability's targets must be **distinct** tokens.
* Filters are evaluated relative to the ability's controller and source
  (`(mine)`, `(enemy)`, `(other)`), using base characteristics (6.2).
* An `(any …)` target that is a **player** is always legal: the filters are
  tested only against a unit.

### 12.3 Legality on resolution

Every target is re-checked at resolution (11.6 step 2) by exactly the same
rules, against the state at that moment. A target is removed when it no longer
exists, has changed zone, no longer matches a filter, or has become protected
by the spectral rule. Distinctness is not re-checked. For a `(chained)` target
the "entry being announced" is, at resolution, the entry being resolved, so an
entry can never target itself.

### 12.4 Rendering and ordering of targets

A target is rendered as `A`, `B`, `#<oid>` or `~<cid>`.

The **target key** of a target is the tuple

* `(0, 0, 0)` for player A, `(0, 1, 0)` for player B;
* `(1, timestamp, oid)` for an object;
* `(2, cid, 0)` for a Chain entry.

Lists of candidate targets are ordered by ascending target key, and tuples of
targets lexicographically by their elements' keys.

---

## 13. Triggered abilities

### 13.1 Events and listeners

An `on <event>` ability of object X, with X's current controller C, listens
while X is on the Field and the ability has not been removed by `strip` — with
the single exception of `leave` and `dies`, which listen for the event of X
itself leaving the Field and so are collected although X has already gone.

| `<event>` | Collected when |
| --- | --- |
| `arrive` | X entered the Field |
| `leave` | X left the Field for any reason |
| `dies` | X was destroyed or sacrificed from the Field |
| `ally-arrive` | a unit other than X, controlled by C, entered the Field |
| `enemy-arrive` | a unit not controlled by C entered the Field |
| `ally-dies` | a unit other than X, controlled by C, died |
| `enemy-dies` | a unit not controlled by C died |
| `turn-start` | the `dawn` step began |
| `your-turn-start` | the `dawn` step of a turn whose active player is C began |
| `turn-end` | the `dusk-trigger` step began |
| `your-turn-end` | the `dusk-trigger` step of C's turn began |
| `attacks` | X was declared an attacker |
| `blocks` | X was declared a blocker |
| `blocked` | X, attacking, became blocked |
| `unblocked` | X, attacking, was determined to be unblocked |
| `damaged` | X was dealt 1 or more damage |
| `deals-damage` | X dealt 1 or more damage |
| `you-play-rite` | C played a rite |
| `enemy-plays-rite` | C's opponent played a rite |
| `you-draw` | C drew a card |
| `spire-loss` | C's Spire decreased |
| `enemy-spire-loss` | C's opponent's Spire decreased |
| `end-of-combat` | the `clash-end` step began while X was attacking or blocking |

A `leave` or `dies` ability is collected after X has left the Field, and an
object that is not on the Field never has its abilities removed by `strip`
(6.2). So a unit that was stripped while on the Field **still** collects its
own `leave` and `dies` triggers when it leaves. The strip test applies in full
to every other event, including `ally-dies` and `enemy-dies` listeners.

"Died" means destroyed or sacrificed. An event is collected once per
qualifying occurrence: three units dying together collect three separate
`ally-dies` triggers from the same listener.

Whether an ability listens is decided **when the event occurs**, and nothing is
re-checked afterwards: a trigger collected from an object that then leaves the
Field before `settle` pushes it is still pushed and still resolves. For a
`leave` or `dies` trigger — and for any trigger from an object that is no
longer on the Field — the ability's controller is the controller the object had
at the moment it left the Field.

### 13.2 The trigger subject `it`

| event | `it` |
| --- | --- |
| `arrive`, `leave`, `dies`, `attacks`, `unblocked`, `end-of-combat` | X itself |
| `ally-arrive`, `enemy-arrive`, `ally-dies`, `enemy-dies` | the other unit |
| `blocks` | the attacker X is blocking |
| `blocked` | the first blocker of X in canonical order |
| `damaged` | the source of the damage (an object, or a player) |
| `deals-damage` | the object or player the damage was dealt to |
| `you-play-rite`, `enemy-plays-rite` | the rite card object |
| `you-draw` | the card object that was drawn |
| `spire-loss`, `enemy-spire-loss` | the player whose Spire decreased |
| `turn-start`, `your-turn-start`, `turn-end`, `your-turn-end` | the active player |

### 13.3 Collection and ordering

Triggers are **collected** into a pending list as their events occur, and
pushed onto the Chain by `settle` (10.5). All triggers collected since the
last push form one batch.

Each pending trigger has a **trigger key**:

```
( 0 if its controller is the active player else 1,
  the timestamp of its source object,
  the oid of its source object,
  the ability index )
```

The timestamp is the one the source object had when the trigger was
**collected**. For a `leave` or `dies` trigger this is the timestamp from its
last stay on the Field, even if the object re-enters the Field before the push.
A delayed trigger (13.5) uses its own creation timestamp, the oid of its
stored source object, and index 0. Timestamps are unique, so the later
components only ever break ties between two abilities of the same object.

The batch is sorted by ascending trigger key; triggers with equal keys (one
ability that triggered more than once) keep the order in which they were
collected. That order is the **trigger order**. Then, in trigger order:

1. choose the trigger's targets automatically (13.4);
2. if it needs targets and has no legal candidate, emit
   `TRIGGER-NO-TARGET <controller> #<oid> <index>` and drop it;
3. otherwise give it a fresh cid and emit
   `TRIGGER <controller> ~<cid> #<oid> <index>` and the rendered targets.

The surviving entries are then placed on the Chain so that the **first in
trigger order is on top** — that is, they resolve in trigger order. (Equivalently,
they are pushed in reverse trigger order.) Entries already on the Chain stay
below the whole batch.

The pending list is cleared. Triggers collected during this push (there are
none: pushing changes no game state) would form the next batch.

### 13.4 Automatic targets

A triggered ability from an `on` clause with a `targets` clause chooses its
targets by rule: for each `<tspec>` in order, take the legal
candidate with the smallest target key that is distinct from the already
chosen targets. If at any point no candidate is available, the trigger is
dropped as in 13.3 step 2.

### 13.5 Delayed triggers

`(delay <when> <effects>)` creates a **delayed trigger** record owned by the
ability's controller, with a fresh timestamp, the ability's source object, the
ability's **current target list** copied as its targets (together with the
target specifications they were checked against, and with every target's
removed mark cleared), and the given effect list. It emits
`DELAY <controller> <when>`.

A delayed trigger is collected when its `<when>` occurs:

* `turn-end` — the `dusk-trigger` step of the current turn;
* `end-of-combat` — the `clash-end` step of the current turn;
* `your-next-turn-start` — the `dawn` step of its controller's next turn.

A collected delayed trigger becomes a `trigger` entry whose ability index is
0, whose effects are the stored ones, and whose targets are the stored ones
(so 11.6 steps 2–3, including fizzling, apply normally). It is then discarded.
`turn-end` and `end-of-combat` delayed triggers that have not fired are
discarded in `dusk-cleanup`, so such a delay registered in a later step than
its trigger point never fires. A `your-next-turn-start` delayed trigger is not
discarded there: it survives into later turns until its controller's next
`dawn` step fires it.

---

## 14. Continuous effects and layers

### 14.1 Records

A **continuous-effect record** has: an **eid**, a positive integer from a
counter starting at 1; a timestamp; a controller; a source object; a kind
(`modify`, `setbody`, `swapstats`, `grant`, `strip`, `control`, `cheaper`); its
arguments; a duration (`turn` or `aura`); and, for duration `turn`, a fixed
list of affected objects.

* A **discrete** record (duration `turn`) is created by the effects `modify`,
  `setbody`, `swapstats`, `grant`, `strip`, `control` when an ability resolves.
  Its amounts are evaluated **once**, at creation. Its affected list is the
  objects the selector matched **at creation**, in canonical order, restricted
  to objects then on the Field. It ends in `dusk-cleanup`. Its controller is
  the ability's controller, fixed at creation. It applies to each object of its
  affected list while that object is on the Field, so an object that leaves and
  re-enters the Field during the same turn is affected again.
* An **aura** record (duration `aura`) comes from an `aura` clause. Its
  selector, amounts and `when` condition are re-evaluated every time
  characteristics are derived. It exists while its source is on the Field and
  the source's abilities are not removed by `strip`.

### 14.2 Creating and ending aura records

When an object enters the Field, one aura record is created for each `aura`
clause of its card, in ability-number order, each taking a fresh timestamp
and a fresh eid. When the object leaves the Field the records are removed.
A `strip` on the source makes its aura records inactive (they contribute
nothing) without destroying them.

### 14.3 Derivation

Current characteristics are derived from **printed** characteristics by
applying every **active** record, layer by layer, lowest layer first:

| Layer | Kind | Effect |
| --- | --- | --- |
| 1 | `control` | the object's controller becomes the record's controller |
| 2 | `grant`, `strip` | `grant` adds a keyword instance; `strip` removes all keyword instances and makes all of the object's abilities (including its aura records) inactive |
| 3 | `setbody` | edge and core are set to the record's values |
| 4 | `modify` | the record's deltas are added to edge and core |
| 5 | charge counters | each charge counter adds +1 to edge and +1 to core |
| 6 | `swapstats` | edge and core are exchanged |

Derivation starts from printed edge, printed core and printed keywords.
Charge counters are applied at layer 5, so a `setbody` at layer 3 does **not**
erase them: a printed 0/3 unit with two counters, a `setbody 0 1` and a
`modify 2 0` ends up at `(0 → 0+2 = 2)/(1 → 1+0 = 1)` after layer 4 and
`4/3` after layer 5.

Within a layer, records apply in ascending `(timestamp, eid)` order. **There
is no dependency rule**: the order is always that, regardless of what the
records do to each other.

Derivation runs in this fixed sequence, which is what keeps it non-circular:

1. Layer 1: current controllers, from the `control` records (all discrete).
2. Which objects are **stripped**: every object in the affected list of a
   `strip` record. This is settled before any aura is looked at, so an aura
   record whose source is stripped contributes nothing whatever the
   timestamps say.
3. Each aura record's activity, affected list and arguments, using the
   controllers of step 1 and base characteristics.
4. Layer 2 keywords, walking the `grant` and `strip` records in
   `(timestamp, eid)` order (14.4).
5. Layers 3, 4, 5 and 6, in that order, each layer's records in
   `(timestamp, eid)` order.

`cheaper` records are not part of derivation; they are consulted by 11.2
step 4.

Edge and core may be negative at any intermediate point and in the final
result. A unit with current core ≤ 0 is destroyed by a state check.

### 14.4 Layer interaction with `strip`

`strip` is a layer-2 record. Because layer 2 applies in `(timestamp, eid)`
order, a `grant` created **before** a `strip` is removed by it, while a
`grant` created **after** it survives. A `strip` does not undo layer-3, 4
or 6 records, nor charge counters, nor `control`.

---

## 15. Replacement and prevention effects

Spiremark has two replacement effects and two prevention pools. When several
apply to the same event they apply in the order given here, each at most once
per event.

### 15.1 Replacement: `tenacity`

When an object would be **destroyed** (17.3) and its current keywords include
`tenacity` and its `tenacity used` flag is clear, the destruction is replaced:
set the flag, remove all wounds from the object, clear its Doomed flag, emit
`TENACITY #<oid>`, and do not destroy it. Sacrifice (17.4) is not destruction
and is never replaced.

### 15.2 Prevention: `plating` and the ward/shield pools

When `n > 0` damage would be dealt to an object or player (17.1):

1. If the target is an object, let `p` be the sum of the values of every
   `plating` instance among its current keywords. Reduce the damage by `p`,
   not below 0.
2. Let `q` be the target's ward pool (an object) or the player's shield pool.
   Let `u = min(q, remaining damage)`. Subtract `u` from both.
3. If anything was prevented, emit `PREVENT <target> <k>` with `k` the total
   prevented. If the remainder is 0, no damage is dealt: no `DAMAGE` event,
   no wounds, no Spire change, no `venom`, no `siphon`, and no `damaged` or
   `deals-damage` trigger.

Spire changes that are not damage (the `spire` effect, a `(spire n)` cost) are
never prevented.

---

## 16. Keywords

Sixteen keywords exist. A keyword is either present or absent, except
`plating`, which has a value and may be present several times (the values
add). "Has keyword K" always means *current* keywords (after layer 2).

### 16.1 Settling

An object is **Settling** while it is on the Field and
`since >= current turn number`, where `since` is set to the current turn number
when the object enters the Field and when a layer-1 `control` record covering
it is created or ends (9.7 step 4). A Settling object may not be declared as an
attacker and may not pay an `(exhaust)` cost, unless it has `vanguard`. This
applies to relics as well as units, so a relic with an `(exhaust)` cost cannot
use it on the turn it arrives (a relic has no printed keywords and no card
grants `vanguard` to a relic).

### 16.2 The keywords

| Keyword | Rule |
| --- | --- |
| `vanguard` | The object ignores Settling (16.1). |
| `vigil` | The unit does not become exhausted when it is declared as an attacker. |
| `riposte` | The unit deals its combat damage in the `clash-riposte` sub-step (19.5). |
| `pierce` | Combat damage this attacker assigns beyond its blockers' needs goes to the defending player (19.6). |
| `ghostwalk` | The unit may be blocked only by a unit with `ghostwalk` or `skyhook`. |
| `skyhook` | The unit may block a unit with `ghostwalk`. |
| `venom` | Any damage this unit deals to a unit marks that unit Doomed (17.16). |
| `siphon` | Whenever this unit deals `m ≥ 1` damage, its current controller gains `m` Spire. |
| `plating N` | Prevention, 15.2. |
| `provoke` | While this unit is attacking, the defending player must block it if able (19.4). |
| `spectral` | Targeting protection, 12.2. |
| `tenacity` | Replacement, 15.1. |
| `siegework` | The unit may not be declared as a blocker. |
| `shackled` | The unit may not be declared as an attacker. |
| `relentless` | The unit must be declared as an attacker whenever it is able to be (19.3). |
| `swift` | A rite with `swift` may be played whenever its controller holds priority (11.1). |

A keyword rendered in output is its name, except `plating`, rendered
`plating:N`. In a `<kwlist>` of a Field object (23.1) `N` is the sum of every
`plating` instance among its current keywords, and every other keyword appears
exactly once however many instances it has. In a `GRANT` event, a `grant <kw>`
effect description or a `CARD` `keywords` line, `N` is the value of that single
`plating` instance.

---

## 17. Damage, destruction and other state changes

Every procedure below is atomic: no state check and no trigger push happens
inside it (section 18).

### 17.1 Dealing damage

To deal `n` damage from source `S` to target `T`:

1. If `n <= 0`, do nothing.
2. Apply prevention (15.2), producing `m`. If `m == 0`, stop.
3. Emit `DAMAGE <S> <T> <m>`, with `S` rendered `#<oid>` or `A`/`B` and `T`
   likewise.
4. If `T` is an object: add `m` wounds.
   If `T` is a player: subtract `m` from their Spire, emit
   `SPIRE <T> -<m> <new>`, and collect `spire-loss` from objects controlled by
   `T` and `enemy-spire-loss` from objects controlled by the opponent.
5. If `T` is a unit and `S` is a unit on the Field with `venom`, mark `T`
   Doomed and emit `DOOM #<T>`. (Re-marking an already-Doomed unit emits the
   event again.)
6. If `S` is a unit on the Field with `siphon`, add `m` to its current
   controller's Spire and emit `SPIRE <controller> +<m> <new>`.
7. Collect `damaged` from `T` if it is an object on the Field, and
   `deals-damage` from `S` if it is an object on the Field.

### 17.2 Simultaneous damage

When one effect deals damage to several targets, or a combat damage sub-step
deals all of its damage, the amounts (and, in combat, the assignments) are
computed first for every source/target pair, then the pairs are applied one by
one in ascending `(source target key, target key)` order by 17.1. No state
check runs until all pairs have been applied.

### 17.3 Destroying an object

1. Apply `tenacity` (15.1); if it applies, stop.
2. Remove the object from the Field and append it to its owner's Ash.
3. Emit `DESTROY #<oid> <cardid>`.
4. Remove its aura records; clear its Field state (7.5).
5. Collect `dies` and `leave` from the object itself, `ally-dies` from the
   other objects controlled by its controller at the moment it left, and
   `enemy-dies` from the objects controlled by the opponent.

### 17.4 Sacrificing an object

As 17.3 but without step 1, and emitting `SACRIFICE #<oid> <cardid>` instead
of `DESTROY`.

### 17.5 Exiling

Remove the object or card from its current zone and append it to its owner's
Rift. Emit `EXILE #<oid> <cardid> <zone>` with `<zone>` the zone it came from
(`field`, `hand`, `ash`, `vault` or `rift`). If it came from the Field,
perform 17.3 steps 4 and collect `leave` only (not `dies`).

### 17.6 Bouncing

Move the Field object to the end of its owner's hand. Emit
`BOUNCE #<oid> <cardid>`, perform 17.3 step 4, and collect `leave`.

### 17.7 Drawing

To make player `P` draw one card: if `P`'s Vault is empty, emit
`DRAW-EMPTY <P>`, mark `P` as having lost with reason `vault`, and stop: the
rest of `P`'s draws from the same effect are skipped. The other player's draws
from that effect still happen. `(draw 2 both)` makes A draw two cards and then
B draw two cards, and an empty Vault cuts short only that player's part.
Otherwise remove the top card, append it to `P`'s hand, emit
`DRAW <P> #<oid> <cardid>`, and collect `you-draw` from objects controlled by
`P`.

### 17.8 Discarding

Remove the card at hand position 1 and append it to its owner's Ash; emit
`DISCARD <P> #<oid> <cardid>`. An empty hand discards nothing, silently.

### 17.9 Milling

Move the top Vault card to its owner's Ash; emit `MILL <P> #<oid> <cardid>`.
An empty Vault mills nothing, silently, and is **not** a loss.

### 17.10 Changing Spire

Add the signed amount to the player's Spire and emit
`SPIRE <P> <+n|-n> <new>`. If the amount is negative, collect `spire-loss`
and `enemy-spire-loss` as in 17.1 step 4. An amount of 0 emits nothing and
collects nothing.

### 17.11 Gaining Ember

Add `n > 0` to the player's Ember (the cap does not limit this) and emit
`EMBERGAIN <P> <n> <new>`. Zero or less does nothing.

### 17.12 Raising the cap

Set the cap to `min(cap + n, MAXCAP)` for `n > 0` and emit
`CAP <P> <n> <newcap>` (even when the cap was already at the maximum).

### 17.13 Taking control

Creating a layer-1 `control` record over a unit also, at creation time:

* sets that unit's `since` to the current turn number;
* removes it from combat — it stops attacking and stops blocking, it is
  removed from the blocker list of whatever it was blocking, every unit that
  was blocking it stops blocking (7.5, Removal from combat), and it will deal
  and receive no combat damage;

and emits `CONTROL #<oid> <newcontroller>` per affected object in canonical
order. A `control` record whose controller already controls the object is
still created and still emits the event.

### 17.14 Charge counters

Add the signed amount, flooring the total at 0. Emit
`COUNTERS #<oid> <+n|-n> <total>` when the total changed; emit nothing when it
did not. The signed field is the **actual** change in the total (new minus
old), which differs from the requested amount when the floor bit.

### 17.15 Ready and exhaust

Set the state and emit `READY #<oid>` or `EXHAUST #<oid>`, only when the state
actually changed.

### 17.16 Dooming

Mark the unit Doomed and emit `DOOM #<oid>`, even if it was already Doomed.

### 17.17 Creating objects, and entering the Field

`(summon <cardid> <n> <psel>)` and `(conjure <cardid> <n> <psel>)` create `n`
objects for each player the selector yields, one at a time. Each takes the
next oid, has that player as owner, and is appended to that player's Field or
hand. Emit `CREATE #<oid> <cardid> <zone>` with `<zone>` `field` or `hand`.
A summoned object then **enters the Field** as below. Each object is created
and, for `summon`, finishes entering the Field — including collecting its
triggers — before the next object is created, so `summon X 2` emits
`CREATE`, `ARRIVE`, `CREATE`, `ARRIVE`.

**Entering the Field** (a resolving `unit`/`relic` entry, a summon, a
reanimate):

1. Place the object on the Field with base controller as specified (the player
   who played it, the summoning player, or the controller of the reanimating
   ability).
2. Give it a fresh timestamp; set `since` to the current turn number; reset
   the state of 7.5.
3. Create its aura records (14.2).
4. Emit `ARRIVE #<oid> <cardid>`.
5. Collect `arrive` from it, and for a unit `ally-arrive`/`enemy-arrive` from
   the other Field objects.

### 17.18 Reanimating

For each matched card that is in an Ash zone and whose type is `unit`: remove
it from that Ash and have it enter the Field (17.17) under the ability's
controller. Its owner does not change. Cards of other types, and cards not in
an Ash, are skipped.

### 17.19 Recalling

Move the matched Ash card to the end of its owner's hand and emit
`RECALL #<oid> <cardid>`.

### 17.20 Negating

For the matched Chain entry: remove it from the Chain and emit
`NEGATE ~<cid>`. If its kind is `rite`, `unit` or `relic`, move the card to
its owner's Ash and emit `SPENT #<oid> <cardid>`.

### 17.21 Digging

`(dig <k> (<filters>) <psel>)`, for each player `P` the selector yields:

1. Let `L` be the top `min(k, |Vault|)` cards of `P`'s Vault, top first;
   remove them from the Vault.
2. Find the first card in `L` matching every filter. If one exists, append it
   to `P`'s hand, emit `DIG <P> #<oid> <cardid>`, and remove it from `L`.
   Otherwise emit `DIG-MISS <P>`.
3. Append the cards remaining in `L` to the **bottom** of `P`'s Vault, in
   their order in `L`, emitting `BOTTOM <P> #<oid> <cardid>` for each.

With `k <= 0`, or an empty Vault, step 1 produces an empty `L`; step 2 emits
`DIG-MISS` and step 3 emits nothing.

---

## 18. State checks

The state checks run only from `settle` (10.5) — never in the middle of an
ability, a cost payment, a damage sub-step or any procedure of section 17.

One run of the state checks does, in order:

1. **Loss check.** If a player's Spire is ≤ 0, that player has lost with
   reason `spire`. Combine with any pending loss already recorded (17.7, a
   concession). If exactly one player has lost, the match ends with the other
   as winner; if both have, it ends in a draw (section 20). Ending the match
   stops everything immediately.
2. **Destruction check.** Collect every unit on the Field whose current core
   is ≤ its wound count, or that is Doomed. If the list is non-empty, destroy
   them all (17.3) in canonical object order and report that the check acted.
3. Nothing else. Relics are never destroyed by a state check.

A unit with current core ≤ 0 and 0 wounds satisfies `core <= wounds` and is
therefore destroyed.

---

## 19. Combat

### 19.1 The clash-attack step

Emit `PHASE clash-attack`, then stop at an `attackers` decision for the active
player. The `ATTACK` command names a set of objects (possibly empty).

If the set is empty: the clash phase ends; proceed to `main2`.

Otherwise, for each attacker in ascending oid order:

1. set its `attacking` status;
2. unless it has `vigil`, exhaust it (17.15);
3. emit `ATTACK #<oid>`.

Then collect `attacks` from each attacker, and run a priority round.

The **defending player** is the other player.

### 19.2 Attack legality

A unit `u` **can attack** when all hold: `u` is on the Field; its current
controller is the active player; its card type is `unit`; it is ready; it is
not Settling or it has `vanguard`; it does not have `shackled`.

An `ATTACK` command is legal when its objects are pairwise distinct, each can
attack, and every unit with `relentless` that can attack is included.

### 19.3 The clash-block step

Emit `PHASE clash-block`, then stop at a `blockers` decision for the defending
player. The `BLOCK` command gives a set of `blocker:attacker` pairs (possibly
empty). Then, in ascending blocker-oid order:

1. set the blocker's `blocking` status and record which attacker it blocks;
2. append it to that attacker's blocker list and set the attacker's `blocked`
   flag;
3. emit `BLOCK #<blocker> #<attacker>`.

Then, for each attacking unit with an empty blocker list, in ascending oid
order, emit `UNBLOCKED #<oid>`.

Then collect, in this order of event kinds (the trigger key decides the final
order anyway): `blocks` from each blocker, `blocked` from each blocked
attacker, `unblocked` from each unblocked attacker. Then run a priority round.

An attacker's blocker list is kept in canonical object order of the blockers.

### 19.4 Block legality

A unit `b` **can block** attacker `a` when all hold: `b` is on the Field; its
current controller is the defending player; its type is `unit`; it is ready;
it does not have `siegework`; `a` is an attacking unit on the Field; and if
`a` has `ghostwalk`, then `b` has `ghostwalk` or `skyhook`. Settling does not
prevent blocking.

A `BLOCK` command is legal when:

* the blockers are pairwise distinct (a unit blocks at most one attacker);
* every pair `(b, a)` satisfies "b can block a";
* **provoke is satisfied**: there is no attacking unit `a` with `provoke`
  whose blocker list is empty while some unit `b` of the defending player that
  the command does not use as a blocker can block `a`.

### 19.5 Damage sub-steps

A unit is **in combat** when it is on the Field and is attacking or blocking.

After the clash-block step ends, if any unit in combat has `riposte`, the
`clash-riposte` step happens: emit `PHASE clash-riposte`, deal the combat
damage of exactly those units in combat that have `riposte` at the moment the
step begins (19.6), then run a priority round. If no unit in combat has
`riposte`, the step is skipped entirely — no `PHASE` event.

Then the `clash-damage` step always happens: emit `PHASE clash-damage`, deal
the combat damage of every unit in combat that did not deal combat damage in
the riposte step, then run a priority round. Every unit in the riposte step's
set counts as having dealt its combat damage, even one that assigned nothing
because its edge was ≤ 0 or its target had gone.

All damage in one sub-step is simultaneous (17.2).

### 19.6 Combat damage assignment

For each unit `u` dealing combat damage in this sub-step, let `e` be its
current edge. If `e <= 0`, `u` assigns nothing.

* `u` is **blocking** attacker `a`: `u` assigns `e` to `a`. (`a` is always
  on the Field here: when an attacker leaves the Field, its blockers stop
  blocking, 7.5.)
* `u` is **attacking** and its `blocked` flag is clear: `u` assigns `e` to the
  defending player.
* `u` is **attacking** and blocked: let `L` be its blocker list restricted to
  blockers still on the Field and still blocking `u`, in canonical order. If
  `L` is empty, `u` assigns nothing. Otherwise walk `L` in order with a
  remaining amount `r = e`: for each blocker `b`, let
  `need = 1` if `u` has `venom`, else `max(0, current core of b - wounds of b)`;
  assign `min(r, need)` to `b` and subtract it from `r`. After the walk, if
  `r > 0`: assign it to the defending player if `u` has `pierce`, otherwise
  add it to the amount assigned to the **last** blocker in `L`.

Assignments of 0 are dropped. The surviving (source, target, amount) triples
are then dealt per 17.2.

### 19.7 The clash-end step

Emit `PHASE clash-end`; collect `end-of-combat` from every unit in combat;
run a priority round; then, when the step ends, clear every object's
`attacking`, `blocking`, `blocked`, blocker list and blocked-attacker fields.

---

## 20. Win and draw conditions

A player **loses** when:

* their Spire is ≤ 0 at a state check — reason `spire`;
* they attempt to draw from an empty Vault (17.7) — reason `vault`; the loss
  is recorded immediately and takes effect at the next state check;
* they concede — reason `concede`; this takes effect immediately, before the
  engine runs forward at all. A player who already has a loss recorded keeps
  that earlier reason.

A player's losing reason is always the **first** one recorded for them. In
particular, a player who drew from an empty Vault and whose Spire is also ≤ 0
at the next state check loses with reason `vault`, not `spire`.

An accepted `CONCEDE` emits no event of its own: the `LOSE` and `RESULT` lines
below are the whole of its output. It is an accepted action, so `TRACE` still
prints its block, describing the ended match.

The match also ends, with no loser, when the turn number would exceed
`TURNLIMIT` — a draw with reason `turn-limit` (9.8).

When the match ends:

* for each losing player, in the order A then B, emit `LOSE <P> <reason>`;
* then emit exactly one `RESULT <winner> <reason>` line, with `<winner>` the
  non-losing player, or `draw` when both lost or the turn limit was reached,
  and `<reason>` the losing reason (`spire`, `vault`, `concede` or
  `turn-limit`; when the two losers have different reasons, A's reason).

A finished match accepts no further actions: every action line produces
`ERR <line> game-over`. Directives still work.

If the script ends while the match is still running, the engine emits
`RESULT pending none` as its final event. Exactly one `RESULT` line is emitted
per run, and it is always the last event line.

---

## 21. Legal actions

The `LEGAL` directive prints the actions that would be accepted at the current
decision point. `CONCEDE` is always accepted from the waiting player and is
never listed.

### 21.1 `priority`

In this order:

1. `PASS`.
2. One `PLAY <pos> <cardid>` line per legal `(hand position, target tuple)`
   combination: for each hand position in ascending order whose card passes
   11.1 and whose Ember cost (11.2 step 4) the player can pay, every tuple of
   targets satisfying section 12 in ascending lexicographic target-key order.
   A card with no `targets` clause contributes exactly one line with no
   targets. A card that needs targets and has no legal tuple contributes
   nothing.
3. One `ACT <#oid> <index>` line per legal `(object, ability, target tuple)`,
   ordered by ascending oid, then ascending ability index, then target tuple.
   An ability whose costs cannot be paid, or that needs targets and has none
   available, contributes nothing.

### 21.2 `attackers`

1. `CANATTACK #<oid>` for each unit that can attack (19.2), ascending oid.
2. `MUSTATTACK #<oid>` for each of those that has `relentless`, ascending oid.

### 21.3 `blockers`

1. `CANBLOCK #<blocker> #<attacker>` for each pair satisfying "can block"
   (19.4), ordered by ascending blocker oid then ascending attacker oid.
2. `MUSTBLOCK #<attacker>` for each attacking unit with `provoke`, ascending
   oid.

---

## 22. Output: event lines

Every rules event is one line

```
<seq> <NAME> <field> <field> …
```

where `<seq>` is a decimal counter starting at 1 and incremented for every
event line emitted. Fields are separated by exactly one space. An object is
rendered `#<oid>`, a player `A` or `B`, a Chain entry `~<cid>`, a card by its
id. A signed field is written with an explicit `+` or `-` and no space.

`ERR` lines and the inspection blocks of section 23 are not events and do not
consume sequence numbers.

### 22.1 Complete list

| Line | Emitted by |
| --- | --- |
| `GAME-START <P>` | setup, naming the first player |
| `SHUFFLE <P>` | setup, after shuffling that player's Vault |
| `TURN <n> <P>` | a turn beginning |
| `PHASE <name>` | a phase or step beginning |
| `EMBER <P> <ember> <cap>` | the `dawn` refresh, 9.1 |
| `EMBERGAIN <P> <n> <ember>` | 17.11 |
| `CAP <P> <n> <cap>` | 17.12 |
| `READY #<oid>` | 17.15, 9.1 |
| `EXHAUST #<oid>` | 17.15, 19.1 |
| `DRAW <P> #<oid> <cardid>` | 17.7 |
| `DRAW-EMPTY <P>` | 17.7 |
| `DIG <P> #<oid> <cardid>` | 17.21 |
| `DIG-MISS <P>` | 17.21 |
| `BOTTOM <P> #<oid> <cardid>` | 17.21 |
| `MILL <P> #<oid> <cardid>` | 17.9 |
| `DISCARD <P> #<oid> <cardid>` | 17.8 |
| `PLAY <P> ~<cid> #<oid> <cardid> [<target>…]` | 11.2 |
| `ACTIVATE <P> ~<cid> #<oid> <idx> [<target>…]` | 11.3 |
| `TRIGGER <P> ~<cid> #<oid> <idx> [<target>…]` | 13.3 |
| `TRIGGER-NO-TARGET <P> #<oid> <idx>` | 13.3 |
| `DELAY <P> <when>` | 13.5 |
| `PAY <P> ember <n>` | 11.2, 11.3 |
| `PAY <P> spire <n>` | 11.3 |
| `RESOLVE ~<cid>` | 11.6 |
| `FIZZLE ~<cid>` | 11.6 |
| `NEGATE ~<cid>` | 17.20 |
| `SPENT #<oid> <cardid>` | 11.6, 17.20 |
| `CREATE #<oid> <cardid> <zone>` | 17.17 |
| `ARRIVE #<oid> <cardid>` | 17.17 |
| `DESTROY #<oid> <cardid>` | 17.3 |
| `SACRIFICE #<oid> <cardid>` | 17.4 |
| `EXILE #<oid> <cardid> <zone>` | 17.5 |
| `BOUNCE #<oid> <cardid>` | 17.6 |
| `RECALL #<oid> <cardid>` | 17.19 |
| `PREVENT <target> <n>` | 15.2 |
| `DAMAGE <source> <target> <n>` | 17.1 |
| `SPIRE <P> <signed> <new>` | 17.1, 17.10 |
| `DOOM #<oid>` | 17.1, 17.16 |
| `TENACITY #<oid>` | 15.1 |
| `WARD #<oid> <n> <pool>` | the `ward` effect |
| `SHIELD <P> <n> <pool>` | the `shield` effect |
| `COUNTERS #<oid> <signed> <total>` | 17.14 |
| `BUFF #<oid> <e> <c>` | a `modify` record's creation, once per affected object |
| `SETBODY #<oid> <e> <c>` | a `setbody` record's creation |
| `SWAP #<oid>` | a `swapstats` record's creation |
| `GRANT #<oid> <keyword>` | a `grant` record's creation |
| `STRIP #<oid>` | a `strip` record's creation |
| `CONTROL #<oid> <P>` | 17.13 |
| `ATTACK #<oid>` | 19.1 |
| `BLOCK #<blocker> #<attacker>` | 19.3 |
| `UNBLOCKED #<oid>` | 19.3 |
| `PASS <P>` | an accepted `PASS` |
| `LOSE <P> <reason>` | section 20 |
| `RESULT <winner> <reason>` | section 20 |

The six record-creation events (`BUFF`, `SETBODY`, `SWAP`, `GRANT`, `STRIP`,
`CONTROL`) are emitted once per object in the record's affected list, in
canonical order, after the record has been created. A record whose affected
list is empty is still created (and still appears in a `DUMP`) but emits no
event. Aura records emit nothing, ever.

`WARD` and `SHIELD` are emitted only when `n > 0`, with `<pool>` the new
total.

---

## 23. Output: inspection blocks

### 23.1 `DUMP`

```
STATE BEGIN
turn <n> active <P> phase <name> decision <P|-> <kind>
result <winner> <reason>
player A spire <s> ember <e> cap <c> vault <n> hand <n> ash <n> rift <n>
player B spire <s> ember <e> cap <c> vault <n> hand <n> ash <n> rift <n>
hand <P> <pos> #<oid> <cardid>
field <P> #<oid> <cardid> <edge>/<core> w<wounds> c<counters> <ready|exhausted> <flags> kw <kwlist>
ash <P> <pos> #<oid> <cardid>
rift <P> <pos> #<oid> <cardid>
chain <pos> ~<cid> <P> <kind> #<oid> <idx> <targets…>
effect <eid> ts<ts> <P> <aura|turn> <desc> on <objs>
delayed <ts> <P> <when> <targets…>
STATE END
```

Rules:

* The `turn` line is always present. `decision` is the waiting player and the
  kind (`priority`, `attackers`, `blockers`); after the match has ended it is
  `decision - over`. When the match ended during setup (step 9), before turn 1
  began, the line reports `turn 1`, the first player as active, and the phase
  `dawn`.
* The `result` line appears only after the match has ended.
* Both `player` lines always appear, A first.
* The zone lines come in the order `hand`, `field`, `ash`, `rift`, and within
  each of those four groups player A's lines come before player B's; a line is
  omitted for an empty zone. Hand, Ash and Rift lines are in position order and
  are grouped by **owner**; `field` lines are in canonical object order and are
  grouped by **current controller**.
* `field` shows **current** edge and core (which may be negative, written with
  a leading `-`), the wound count, the charge-counter count, the ready state,
  the flags, and the current keywords. A relic shows `-/-` for edge/core.
* `<flags>` is a comma-separated, lexicographically ascending list of the
  flags that hold, or `-` when none hold:
  `attacking`, `blocked`, `blocking`, `doomed`, `once<idx>` (one per used
  `(once)` ability index, e.g. `once3`), `settling`, `tenacity-used`,
  `ward<n>` (when the ward pool is `n > 0`).
* `<kwlist>` is a comma-separated, lexicographically ascending list of the
  current keywords, with `plating` rendered `plating:N`, or `-` when there
  are none.
* `chain` lines are printed bottom first, `<pos>` counting from 1 at the
  bottom. `<kind>` is `rite`, `unit`, `relic`, `ability` or `trigger`.
  `<targets…>` are the rendered targets, with a removed target rendered `-`;
  nothing is printed when the entry has no targets.
* `effect` lines list every existing continuous-effect record, ascending by
  eid. `<desc>` is one of `modify <e> <c>`, `setbody <e> <c>`, `swapstats`,
  `grant <keyword>`, `strip`, `control <P>`, `cheaper <n>`. `<objs>` is the
  comma-separated list of affected objects (`#7,#9`) — for a discrete record
  its fixed list restricted to the objects now on the Field, for an aura record
  the objects it currently matches, in canonical order — or `-` when empty. An
  inactive aura record (source stripped, or a false `when`) prints `<objs>` as
  `-`, but still prints the `<desc>` its arguments would evaluate to now. A
  `cheaper` record prints `on -`. `<P>` is the record's controller: the
  ability's controller for a discrete record, the source's current controller
  for an aura record (6.11).
* `delayed` lines list the pending delayed triggers, ascending by timestamp.
* Lines whose list is empty are omitted entirely (no empty `hand`, `field`,
  `ash`, `rift`, `chain`, `effect`, `delayed` lines).

### 23.2 `LEGAL`

```
LEGAL BEGIN <P> <kind>
<action lines, section 21>
LEGAL END
```

After the match has ended, the header is `LEGAL BEGIN - over` and there are no
action lines.

### 23.3 `VAULT`

```
VAULT BEGIN
vault A <pos> #<oid> <cardid>
vault B <pos> #<oid> <cardid>
VAULT END
```

Player A's Vault top-down, then player B's. An empty Vault prints no lines.

### 23.4 `CARD <cardid>`

```
CARD BEGIN <cardid>
name <name>
type <type>
cost <n>
body <edge>/<core>
tags <t>,<t>,…
keywords <k>,<k>,…
ability <n> <rendering>
CARD END
```

* `name` prints the string's contents without quotes.
* `body` appears only for a unit.
* `tags` prints the tags in **file order**, comma-separated, or `-`.
* `keywords` prints the printed keywords in ascending lexicographic order of
  their rendering (`plating:N` sorts as that string), or `-`.
* One `ability` line per ability, in ability-number order (5.3), rendered as:
  * `resolve <targetspec> <effects>`
  * `on <event> <targetspec> <effects>`
  * `act <costspec> <targetspec> <effects>`
  * `aura <statics>`

  where `<targetspec>` is the canonical printing of the `targets` clause or
  `-` when absent, `<costspec>` is the canonical printing of the `cost`
  clause, and `<effects>` / `<statics>` are the canonical printings of those
  forms separated by single spaces.
* If the card id is not in the database, the block is

  ```
  CARD BEGIN <cardid>
  unknown
  CARD END
  ```

**Canonical s-expression printing.** A list is `(` + its elements joined by
single spaces + `)`. A symbol prints as itself. An integer prints in minimal
decimal with a leading `-` when negative. A string prints as `"` + contents +
`"`. No other whitespace appears. The forms are printed with exactly the
elements the file gave, in the same order — the printer normalises whitespace
only.

---

## 24. Errors

A script action line that is not accepted emits

```
ERR <line> <kind>
```

where `<line>` is the 1-based line number of that line in the input (counting
every line, comments included) and `<kind>` is a token from the table below.
The action has **no effect at all**: no cards move, no Ember is paid, no
events are emitted, the decision point does not change.

Checks are applied in exactly this order; the first that fails names the kind.

| # | kind | Condition |
| --- | --- | --- |
| 1 | `bad-syntax` | the line does not match section 4.2 — unknown first word, unknown action word, wrong number of words, malformed `<pos>`/`<index>`/`<objref>`/`<target>`/`<pair>`, a number that does not fit in 64 bits |
| 2 | `game-over` | the match has ended |
| 3 | `not-your-turn` | the acting player is not the player the engine is waiting for |
| 4 | `wrong-decision` | the action kind does not match the decision kind: `PASS`/`PLAY`/`ACT` outside a `priority` decision, `ATTACK` outside an `attackers` decision, `BLOCK` outside a `blockers` decision. (`CONCEDE` matches every decision.) |

A script line that is neither a comment nor a well-formed action is also a
`bad-syntax` error, including a malformed directive (`DUMP x`, a bare `CARD`,
`CARD a b`): check 1 applies to every non-comment line, so it is reported even
after the match has ended. A well-formed directive is never an error.

Then, by action:

**`PLAY <pos> …`**

| # | kind | Condition |
| --- | --- | --- |
| 5 | `no-such-card` | `pos` is 0 or greater than the hand size |
| 6 | `bad-timing` | the card may not be played now (11.1) |
| 7 | `bad-target-count` | the number of targets given differs from the `targets` clause's length (0 when there is none) |
| 8 | `illegal-target` | some target is not a legal target for its `<tspec>`, or two targets are the same token |
| 9 | `cannot-afford` | the player's Ember is less than the computed cost |

A `#<n>` target naming no existing object, and a `~<n>` target naming no entry
now on the Chain, are `illegal-target`, not `bad-syntax`.

**`ACT <#oid> <index> …`**

| # | kind | Condition |
| --- | --- | --- |
| 5 | `no-such-object` | no object with that oid is on the Field under the actor's control |
| 6 | `no-such-ability` | the index is not an ability number of that card, or does not name an `act` ability, or the object's abilities are removed by `strip` |
| 7 | `bad-target-count` | as above |
| 8 | `illegal-target` | as above |
| 9 | `cost-unpayable` | some cost item cannot be paid (11.3 step 4) |

**`ATTACK …`**

| # | kind | Condition |
| --- | --- | --- |
| 5 | `duplicate-attacker` | an oid appears twice |
| 6 | `illegal-attacker` | some named object cannot attack (19.2) |
| 7 | `missing-required-attacker` | a `relentless` unit that can attack was omitted |

**`BLOCK …`**

| # | kind | Condition |
| --- | --- | --- |
| 5 | `duplicate-blocker` | a blocker oid appears twice |
| 6 | `illegal-blocker` | some pair fails "can block" (19.4) |
| 7 | `missing-required-block` | provoke is not satisfied (19.4) |

An `<objref>` naming no existing object fails "can attack" / "can block", so it
gives `illegal-attacker` or `illegal-blocker`.

`CONCEDE` and `PASS` have no further checks.

Setup problems are fatal and print a single `FATAL …` line (section 8); they
are the only cases in which no event lines at all are printed.

---

## 25. Pseudo-random number generator

A 64-bit xorshift\* generator. All arithmetic is on unsigned 64-bit integers,
with shifts logical and multiplication and xor taken modulo 2^64.

```
state := SEED
if state == 0: state := 0x2545F4914F6CDD1D

next():
    state ^= state >> 12
    state ^= state << 25
    state ^= state >> 27
    return state * 0x2545F4914F6CDD1D

below(n):            # n >= 1
    return next() % n
```

For `SEED 7` the first five values of `next()` are

```
15130880334998875822
17123930943180875438
1648209070578717474
1985375592982671918
6908966637734145041
```

**Shuffling** a list `L` of length `k`:

```
for i := k-1 down to 1:
    j := below(i+1)
    swap L[i] and L[j]
```

A list of length 0 or 1 consumes no randomness.

**`random-unit`**: build the ordered list the equivalent `units` selector
would give; if it is empty, yield nothing and consume no randomness;
otherwise yield element `below(count)` of it (0-based).

The generator is used nowhere else. Every other choice in the game is fixed by
a rule.

---

## 26. Worked examples

All examples use the shipped `data/cards.spire`. The examples were traced by
hand against this document; where an example and the rules text disagree, the
rules text is normative.

### 26.1 `CARD` — a rite, a relic with two auras, a unit with two abilities

Input

```
CARDS data/cards.spire
SEED 1
OPENING 0
SHUFFLE off
START
CARD CIN-003
CARD LOM-039
CARD DSK-020
CARD ZZZ-999
```

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
CARD BEGIN CIN-003
name Searing Bolt
type rite
cost 1
tags cinder
keywords swift
ability 1 resolve (targets (any)) (damage 2 (t 1))
CARD END
CARD BEGIN LOM-039
name Heartwood Shrine
type relic
cost 5
tags loam
keywords -
ability 1 aura (modify 1 1 (units yours))
ability 2 aura (grant (plating 1) (units yours))
CARD END
CARD BEGIN DSK-020
name Grim Harvester
type unit
cost 3
body 2/2
tags dusk,undead
keywords -
ability 1 on spire-loss - (counters 1 self)
ability 2 act (cost (exhaust) (spire 2)) (targets (unit)) (damage 2 (t 1))
CARD END
CARD BEGIN ZZZ-999
unknown
CARD END
8 RESULT pending none
```

The `CARD` blocks come *after* the setup and turn-1 event lines, because the
engine runs forward to the first decision point before reading the first
script line. `OPENING 0` is needed because both Vaults are empty: with the
default opening hand of 5 both players would draw from an empty Vault and the
match would end at once. `SHUFFLE off` suppresses the two `SHUFFLE` events
that an empty Vault would otherwise still produce.

`DSK-020`'s ability 1 prints `-` for its target specification because its `on`
clause has no `targets`. Its ability 2 is an `act`, so its cost clause is
printed in full.

### 26.2 `FATAL unknown-card`

Input

```
CARDS data/cards.spire
SEED 1
DECK A ZZZ-999
START
```

Output

```
FATAL unknown-card
```

### 26.3 Setup and `DUMP`

Input

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001*3
DECK B CIN-001*3
HAND A CIN-003
FIELD B CIN-001
START
DUMP
```

Oids: A's three deck cards are `#1 #2 #3`, A's hand card is `#4`; B's three
deck cards are `#5 #6 #7` and B's Field card is `#8` (timestamp 1).

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
STATE BEGIN
turn 1 active A phase main1 decision A priority
player A spire 10 ember 1 cap 1 vault 3 hand 1 ash 0 rift 0
player B spire 10 ember 0 cap 0 vault 3 hand 0 ash 0 rift 0
hand A 1 #4 CIN-003
field B #8 CIN-001 2/1 w0 c0 ready - kw vanguard
STATE END
8 RESULT pending none
```

`dawn` raised A's cap from 0 to 1 and set both Embers to their caps; `draw`
did nothing because this is turn 1 and A is the first player; `main1` gave A
priority, which is the decision point the `DUMP` describes. B's Field unit is
not Settling because setup gives `since = 0`.

### 26.4 A rite kills a unit

Input

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003
FIELD B TOK-001
START
A PLAY 1 #4
A PASS
B PASS
A PASS
B PASS
```

Oids: `#1` A's deck card, `#2` A's hand card, `#3` B's deck card, `#4` B's
`TOK-001` (timestamp 1).

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 CIN-003 #4
9 PAY A ember 1
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DAMAGE #2 #4 2
14 SPENT #2 CIN-003
15 DESTROY #4 TOK-001
16 PASS A
17 PASS B
18 PHASE clash-attack
19 RESULT pending none
```

The two passes at lines 10–11 resolve the rite; the state check that follows
the resolution destroys `#4` (2 wounds, core 1). The two passes at 16–17 end
`main1`, and the engine stops at the `attackers` decision in `clash-attack`.

### 26.5 Riposte combat

Input

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-006
DECK B CIN-001
FIELD A CIN-006
FIELD B TOK-001
START
A PASS
B PASS
A ATTACK #2
A PASS
B PASS
B BLOCK #4:#2
A PASS
B PASS
A PASS
B PASS
```

Oids: `#1` A's deck card, `#2` A's `CIN-006` (Ashblade Duelist 2/1 riposte,
timestamp 1), `#3` B's deck card, `#4` B's `TOK-001` (1/1, timestamp 2).

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PASS A
9 PASS B
10 PHASE clash-attack
11 EXHAUST #2
12 ATTACK #2
13 PASS A
14 PASS B
15 PHASE clash-block
16 BLOCK #4 #2
17 PASS A
18 PASS B
19 PHASE clash-riposte
20 DAMAGE #2 #4 2
21 DESTROY #4 TOK-001
22 PASS A
23 PASS B
24 PHASE clash-damage
25 RESULT pending none
```

`#2` has `riposte`, so the riposte sub-step happens and only `#2` deals
damage there. Assignment: the blocker list is `[#4]`; `#4` needs 1 (core 1,
no wounds); the remaining 1 is not `pierce`, so it is added to the last
blocker, giving 2. The state check destroys `#4`. In `clash-damage` nothing is
left to deal damage — `#2` already dealt its damage and `#4` is gone — so the
step emits only its `PHASE` line before giving priority.

### 26.6 Trigger ordering across three listeners

Input

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 3
DECK A CIN-001
DECK B CIN-001
HAND A DSK-002
FIELD A CIN-018 DSK-036 TOK-001
FIELD B DSK-005
START
A PLAY 1 #5
A PASS
B PASS
A PASS
B PASS
A PASS
B PASS
A PASS
B PASS
A PASS
B PASS
DUMP
```

Oids: `#1` A's deck card, `#2` `DSK-002` in A's hand, `#3` `CIN-018`
(timestamp 1), `#4` `DSK-036` (timestamp 2), `#5` `TOK-001` (timestamp 3),
`#6` B's deck card, `#7` `DSK-005` (timestamp 4).

`#5` dying collects three triggers: `CIN-018`'s `ally-dies` (ability 1),
`DSK-036`'s `ally-dies` (ability 1) and `DSK-005`'s `enemy-dies` (ability 1).
Trigger keys: `(0,1,3,1)`, `(0,2,4,1)`, `(1,4,7,1)` — A is the active player,
so both of A's triggers come first, ordered by timestamp.

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 4 4
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 DSK-002 #5
9 PAY A ember 2
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DESTROY #5 TOK-001
14 SPENT #2 DSK-002
15 TRIGGER A ~2 #3 1
16 TRIGGER A ~3 #4 1
17 TRIGGER B ~4 #7 1
18 PASS A
19 PASS B
20 RESOLVE ~2
21 DAMAGE #3 B 1
22 SPIRE B -1 9
23 PASS A
24 PASS B
25 RESOLVE ~3
26 SPIRE A +1 11
27 PASS A
28 PASS B
29 RESOLVE ~4
30 COUNTERS #7 +1 1
31 PASS A
32 PASS B
33 PHASE clash-attack
STATE BEGIN
turn 1 active A phase clash-attack decision A attackers
player A spire 11 ember 2 cap 4 vault 1 hand 0 ash 2 rift 0
player B spire 9 ember 0 cap 0 vault 1 hand 0 ash 0 rift 0
field A #3 CIN-018 3/4 w0 c0 ready - kw -
field A #4 DSK-036 2/4 w0 c0 ready - kw -
field B #7 DSK-005 5/4 w0 c1 ready - kw -
ash A 1 #5 TOK-001
ash A 2 #2 DSK-002
STATE END
34 RESULT pending none
```

`~2` is on top of the Chain and resolves first, matching the trigger order.
`#7` shows 5/4 because its printed body is 4/3 and it has one charge counter.

### 26.7 Layers

Input

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 4
DECK A CIN-001
DECK B CIN-001
HAND A LOM-003 TID-022 CIN-011
FIELD A TOK-003
START
A PLAY 1 #5
A PASS
B PASS
A PLAY 1 #5
A PASS
B PASS
A PLAY 1 #5
A PASS
B PASS
DUMP
```

Oids: `#1` A's deck card, `#2 LOM-003`, `#3 TID-022`, `#4 CIN-011` in A's
hand, `#5 TOK-003` (Stone Sentinel 0/3 plating 1, timestamp 1).

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 5 5
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 LOM-003 #5
9 PAY A ember 2
10 PASS A
11 PASS B
12 RESOLVE ~1
13 COUNTERS #5 +2 2
14 SPENT #2 LOM-003
15 PLAY A ~2 #3 TID-022 #5
16 PAY A ember 2
17 PASS A
18 PASS B
19 RESOLVE ~2
20 SETBODY #5 0 1
21 SPENT #3 TID-022
22 PLAY A ~3 #4 CIN-011 #5
23 PAY A ember 1
24 PASS A
25 PASS B
26 RESOLVE ~3
27 BUFF #5 2 0
28 GRANT #5 pierce
29 SPENT #4 CIN-011
STATE BEGIN
turn 1 active A phase main1 decision A priority
player A spire 10 ember 0 cap 5 vault 1 hand 0 ash 3 rift 0
player B spire 10 ember 0 cap 0 vault 1 hand 0 ash 0 rift 0
field A #5 TOK-003 4/3 w0 c2 ready - kw pierce,plating:1
ash A 1 #2 LOM-003
ash A 2 #3 TID-022
ash A 3 #4 CIN-011
effect 1 ts2 A turn setbody 0 1 on #5
effect 2 ts3 A turn modify 2 0 on #5
effect 3 ts4 A turn grant pierce on #5
STATE END
30 RESULT pending none
```

Derivation of `4/3`: printed body `0/3`; layer 3 `setbody 0 1` makes it `0/1`;
layer 4 `modify 2 0` makes it `2/1`; layer 5 adds the two charge counters,
giving `4/3`; layer 6 does nothing. The keywords are the printed `plating 1`
plus the granted `pierce`, rendered in ascending order as
`pierce,plating:1`.

The three records show the shared timestamp counter at work: `#5` took
timestamp 1 when setup put it on the Field, so the `setbody`, `modify` and
`grant` records took 2, 3 and 4 as they were created, which is also their
layer order within each layer. The `modify` and `grant` created by the same
resolution still take two separate timestamps.

### 26.8 `tenacity` as a replacement effect

Input

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 3
DECK A CIN-001
DECK B CIN-001
HAND A CIN-005 CIN-005
FIELD B DSK-024
START
A PLAY 1 #5
A PASS
B PASS
A PLAY 1 #5
A PASS
B PASS
DUMP
```

Oids: `#1` A's deck card, `#2` and `#3` the two `CIN-005` in A's hand, `#4`
B's deck card, `#5 DSK-024` (Deathless Knight 3/3 tenacity, timestamp 1).

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 4 4
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 CIN-005 #5
9 PAY A ember 2
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DAMAGE #2 #5 3
14 SPENT #2 CIN-005
15 TENACITY #5
16 PLAY A ~2 #3 CIN-005 #5
17 PAY A ember 2
18 PASS A
19 PASS B
20 RESOLVE ~2
21 DAMAGE #3 #5 3
22 SPENT #3 CIN-005
23 DESTROY #5 DSK-024
STATE BEGIN
turn 1 active A phase main1 decision A priority
player A spire 10 ember 0 cap 4 vault 1 hand 0 ash 2 rift 0
player B spire 10 ember 0 cap 0 vault 1 hand 0 ash 1 rift 0
ash A 1 #2 CIN-005
ash A 2 #3 CIN-005
ash B 1 #5 DSK-024
STATE END
24 RESULT pending none
```

The first state check after `~1` would destroy `#5`; `tenacity` replaces that,
clearing the wounds and setting the used flag. The second lance kills it
because the flag is only cleared at the next `dawn`.

### 26.9 Fizzling

Input

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 1
CAP B 1
DECK A CIN-001
DECK B CIN-001
HAND A CIN-005
HAND B TID-003
FIELD B TOK-001
START
A PLAY 1 #5
A PASS
B PLAY 1 #5
B PASS
A PASS
A PASS
B PASS
DUMP
```

Oids: `#1` A's deck card, `#2 CIN-005` in A's hand, `#3` B's deck card,
`#4 TID-003` in B's hand, `#5 TOK-001` on B's Field (timestamp 1).

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 2 2
5 EMBER B 1 1
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 CIN-005 #5
9 PAY A ember 2
10 PASS A
11 PLAY B ~2 #4 TID-003 #5
12 PAY B ember 1
13 PASS B
14 PASS A
15 RESOLVE ~2
16 BOUNCE #5 TOK-001
17 SPENT #4 TID-003
18 PASS A
19 PASS B
20 RESOLVE ~1
21 FIZZLE ~1
22 SPENT #2 CIN-005
STATE BEGIN
turn 1 active A phase main1 decision A priority
player A spire 10 ember 0 cap 2 vault 1 hand 0 ash 1 rift 0
player B spire 10 ember 0 cap 1 vault 1 hand 1 ash 1 rift 0
hand B 1 #5 TOK-001
ash A 1 #2 CIN-005
ash B 1 #4 TID-003
STATE END
23 RESULT pending none
```

The pass counter runs: A plays (0, A holds), A passes (1, B holds), B plays
(back to 0 — 10.3 — with B holding), B passes (1, A holds), A passes (2) so
the top entry `~2` resolves. `~2` bounces `#5` to B's hand. After the
resolution A holds priority with the counter at 0, and the pair of passes at
events 18–19 resolves `~1`, which fizzles: its only target is no longer a unit
on the Field, so every target is removed and the rite goes to Ash without
dealing damage.

### 26.10 `LEGAL` at all three decision kinds

Input

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 2
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003 CIN-027
FIELD A TOK-001
FIELD B TOK-005
START
LEGAL
A PASS
B PASS
LEGAL
A ATTACK #4
A PASS
B PASS
LEGAL
```

Oids: `#1` A's deck card, `#2 CIN-003`, `#3 CIN-027` in A's hand, `#4 TOK-001`
on A's Field (timestamp 1), `#5` B's deck card, `#6 TOK-005` on B's Field
(timestamp 2).

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 3 3
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
LEGAL BEGIN A priority
PASS
PLAY 1 CIN-003 A
PLAY 1 CIN-003 B
PLAY 1 CIN-003 #4
PLAY 1 CIN-003 #6
PLAY 2 CIN-027
LEGAL END
8 PASS A
9 PASS B
10 PHASE clash-attack
LEGAL BEGIN A attackers
CANATTACK #4
LEGAL END
11 EXHAUST #4
12 ATTACK #4
13 PASS A
14 PASS B
15 PHASE clash-block
LEGAL BEGIN B blockers
CANBLOCK #6 #4
LEGAL END
16 RESULT pending none
```

`CIN-003` takes one `(any)` target: both players and both units qualify, and
players sort before objects. `CIN-027` is a unit with no `targets` clause, so
it contributes a single line. `TOK-001` has no abilities, so there are no
`ACT` lines.

### 26.11 Error kinds and precedence

Input (line numbers shown for reference only; they are not part of the file)

```
 1  CARDS data/cards.spire
 2  SEED 1
 3  SPIRE 10
 4  OPENING 0
 5  SHUFFLE off
 6  DECK A CIN-001
 7  DECK B CIN-001
 8  HAND A CIN-003 CIN-016
 9  START
10  X PASS
11  B PASS
12  A BLOCK
13  A PLAY 5
14  A PLAY 1
15  A PLAY 1 #99
16  A PLAY 2
17  A PLAY 1 A
```

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
ERR 10 bad-syntax
ERR 11 not-your-turn
ERR 12 wrong-decision
ERR 13 no-such-card
ERR 14 bad-target-count
ERR 15 illegal-target
ERR 16 cannot-afford
8 PLAY A ~1 #2 CIN-003 A
9 PAY A ember 1
10 RESULT pending none
```

Line 16 plays `CIN-016`, a non-`swift` rite costing 4, during A's own `main1`
with an empty Chain: the timing is legal, so the reported kind is
`cannot-afford` and not `bad-timing`.

### 26.12 Shuffling and `VAULT`

Input

```
CARDS data/cards.spire
SEED 7
SPIRE 10
OPENING 0
DECK A CIN-001 CIN-002 CIN-003 TID-001 TID-002 LOM-001 LOM-002 DSK-001
DECK B CIN-001 CIN-002 CIN-003 TID-001 TID-002 LOM-001 LOM-002 DSK-001
START
VAULT
```

A's deck cards are `#1`…`#8` in the order written; B's are `#9`…`#16`.

Output

```
1 GAME-START A
2 SHUFFLE A
3 SHUFFLE B
4 TURN 1 A
5 PHASE dawn
6 EMBER A 1 1
7 EMBER B 0 0
8 PHASE draw
9 PHASE main1
VAULT BEGIN
vault A 1 #6 LOM-001
vault A 2 #8 DSK-001
vault A 3 #5 TID-002
vault A 4 #2 CIN-002
vault A 5 #4 TID-001
vault A 6 #1 CIN-001
vault A 7 #3 CIN-003
vault A 8 #7 LOM-002
vault B 1 #16 DSK-001
vault B 2 #14 LOM-001
vault B 3 #9 CIN-001
vault B 4 #15 LOM-002
vault B 5 #10 CIN-002
vault B 6 #11 CIN-003
vault B 7 #12 TID-001
vault B 8 #13 TID-002
VAULT END
10 RESULT pending none
```

A's shuffle performs the swaps `(i=7,j=6) (6,2) (5,0) (4,3) (3,1) (2,1)
(1,1)`, consuming seven values of `next()`; B's shuffle continues the same
stream with `(7,4) (6,3) (5,2) (4,1) (3,3) (2,0) (1,0)`.

### 26.13 Winning on Spire

Input

```
CARDS data/cards.spire
SEED 1
SPIRE 2
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003
START
A PLAY 1 B
A PASS
B PASS
A PASS
```

Output

```
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 CIN-003 B
9 PAY A ember 1
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DAMAGE #2 B 2
14 SPIRE B -2 0
15 SPENT #2 CIN-003
16 LOSE B spire
17 RESULT A spire
ERR 13 game-over
```

Input line 13 is the final `A PASS`, which arrives after the match has ended.

---

## 27. Index of card ids

The main database `data/cards.spire` defines 200 cards:

* `TOK-001`…`TOK-008` — tokens, cost 0, created only by `summon` and
  `conjure`. Tests never put them in a `DECK` line, but they may appear in
  `HAND`, `FIELD`, `ASH` and `RIFT` setup lines.

In every test, with every database, a `FIELD` setup line names only `unit`
and `relic` cards, never a `rite`.
* `CIN-001`…`CIN-040` — Cinder: direct damage, `riposte`, `pierce`,
  `vanguard`.
* `TID-001`…`TID-040` — Tide: drawing, `bounce`, `negate`, `ghostwalk`,
  `swift`.
* `LOM-001`…`LOM-040` — Loam: charge counters, auras, `plating`, ramp.
* `DSK-001`…`DSK-040` — Dusk: destruction, `venom`, reanimation, discard.
* `NEU-001`…`NEU-032` — Neutral: utility, relics, token makers.

Nothing about a card is implied by its house beyond what its definition in
`data/cards.spire` says.
