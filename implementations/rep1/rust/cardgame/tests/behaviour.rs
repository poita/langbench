//! Behavioural tests of the public API, one rule at a time.

use std::path::PathBuf;

fn data(name: &str) -> String {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/data")
        .join(name)
        .display()
        .to_string()
}

/// Run a match against `cards.spire`; `body` is everything after `CARDS`.
fn run(body: &str) -> Vec<String> {
    let input = format!("CARDS {}\n{body}", data("cards.spire"));
    cardgame::run_match(&input).lines().map(str::to_string).collect()
}

const BASE: &str = "SEED 1\nSPIRE 10\nOPENING 0\nSHUFFLE off\n";

#[test]
fn missing_start_is_bad_setup() {
    assert_eq!(run("SEED 1\n"), ["FATAL bad-setup"]);
}

#[test]
fn bad_database_paths() {
    let input = format!("CARDS {}\nSEED 1\nSTART\n", data("bad/01_unbalanced.spire"));
    assert_eq!(cardgame::run_match(&input), "FATAL bad-database\n");
    let input = "CARDS /no/such/file.spire\nSEED 1\nSTART\n";
    assert_eq!(cardgame::run_match(input), "FATAL bad-database\n");
}

#[test]
fn every_bad_database_is_rejected() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/data/bad");
    let mut n = 0;
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        assert!(
            cardgame::Database::load(path.to_str().unwrap()).is_err(),
            "accepted {}",
            path.display()
        );
        n += 1;
    }
    assert!(n >= 50);
}

#[test]
fn shipped_databases_are_valid() {
    for name in ["cards.spire", "extra.spire", "lexer.spire", "empty.spire"] {
        cardgame::Database::load(&data(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
    }
    assert_eq!(cardgame::Database::load(&data("cards.spire")).unwrap().len(), 200);
}

#[test]
fn unknown_card_is_fatal() {
    assert_eq!(run(&format!("{BASE}DECK A NOPE-001\nSTART\n")), ["FATAL unknown-card"]);
}

#[test]
fn empty_vault_at_setup_loses_immediately() {
    let out = run("SEED 1\nOPENING 1\nSHUFFLE off\nSTART\nDUMP\n");
    assert!(out.contains(&"2 DRAW-EMPTY A".to_string()));
    assert!(out.iter().any(|l| l.starts_with("RESULT") || l.contains(" RESULT draw vault")));
    assert!(out.contains(&"decision - over".to_string()) || out.iter().any(|l| l.ends_with("decision - over")));
}

#[test]
fn concede_ends_the_match_and_later_actions_are_rejected() {
    let out = run(&format!("{BASE}DECK A CIN-001\nDECK B CIN-001\nSTART\nA CONCEDE\nB PASS\nDUMP\n"));
    assert!(out.contains(&"8 LOSE A concede".to_string()));
    assert!(out.contains(&"9 RESULT B concede".to_string()));
    assert!(out.contains(&"ERR 10 game-over".to_string()));
    assert!(out.contains(&"result B concede".to_string()));
}

#[test]
fn turn_limit_is_a_draw() {
    let mut script = String::new();
    for _ in 0..8 {
        // Each turn: both pass in main1, attack nothing, both pass in main2 and dusk.
        script.push_str("A PASS\nB PASS\nA ATTACK\nA PASS\nB PASS\nA PASS\nB PASS\n");
        script.push_str("B PASS\nA PASS\nB ATTACK\nB PASS\nA PASS\nB PASS\nA PASS\n");
    }
    let out = run(&format!(
        "{BASE}TURNLIMIT 2\nDECK A CIN-001*10\nDECK B CIN-001*10\nSTART\n{script}"
    ));
    assert!(out.iter().any(|l| l.ends_with("RESULT draw turn-limit")), "{out:?}");
}

#[test]
fn error_precedence() {
    let out = run(&format!(
        "{BASE}DECK A CIN-001\nDECK B CIN-001\nHAND A CIN-003\nSTART\nX PASS\nB PASS\nA BLOCK\nA PLAY 5\nA PLAY 1\nA PLAY 1 #99\nA PLAY 1 A\n"
    ));
    let errs: Vec<&str> = out.iter().filter(|l| l.starts_with("ERR")).map(String::as_str).collect();
    assert_eq!(
        errs,
        [
            "ERR 10 bad-syntax",
            "ERR 11 not-your-turn",
            "ERR 12 wrong-decision",
            "ERR 13 no-such-card",
            "ERR 14 bad-target-count",
            "ERR 15 illegal-target"
        ]
    );
}

#[test]
fn comments_count_for_line_numbers() {
    let out = run(&format!("{BASE}START\n# a comment\n\nA FLY\n"));
    assert!(out.contains(&"ERR 9 bad-syntax".to_string()), "{out:?}");
}

#[test]
fn card_directive_prints_canonical_form() {
    let out = run(&format!("{BASE}START\nCARD CIN-003\nCARD NOPE-000\n"));
    let i = out.iter().position(|l| l == "CARD BEGIN CIN-003").unwrap();
    assert_eq!(out[i + 1], "name Searing Bolt");
    assert_eq!(out[i + 5], "keywords swift");
    assert_eq!(out[i + 6], "ability 1 resolve (targets (any)) (damage 2 (t 1))");
    assert!(out.contains(&"unknown".to_string()));
}

#[test]
fn shuffle_is_deterministic_per_seed() {
    let deck = "DECK A CIN-001 CIN-002 CIN-003 TID-001 TID-002 LOM-001 LOM-002 DSK-001\n";
    let a = run(&format!("SEED 7\nSPIRE 10\nOPENING 0\n{deck}START\nVAULT\n"));
    let b = run(&format!("SEED 7\nSPIRE 10\nOPENING 0\n{deck}START\nVAULT\n"));
    let c = run(&format!("SEED 8\nSPIRE 10\nOPENING 0\n{deck}START\nVAULT\n"));
    assert_eq!(a, b);
    assert_ne!(a, c);
    assert!(a.contains(&"vault A 1 #6 LOM-001".to_string()));
}

#[test]
fn spire_loss_ends_the_match() {
    let out = run(
        "SEED 1\nSPIRE 2\nOPENING 0\nSHUFFLE off\nDECK A CIN-001\nDECK B CIN-001\nHAND A CIN-003\nSTART\nA PLAY 1 B\nA PASS\nB PASS\nA PASS\n",
    );
    assert!(out.contains(&"16 LOSE B spire".to_string()));
    assert!(out.contains(&"17 RESULT A spire".to_string()));
    assert!(out.contains(&"ERR 13 game-over".to_string()));
}

#[test]
fn legal_lists_pass_first() {
    let out = run(&format!("{BASE}CAP A 2\nDECK A CIN-001\nDECK B CIN-001\nHAND A CIN-027\nSTART\nLEGAL\n"));
    let i = out.iter().position(|l| l == "LEGAL BEGIN A priority").unwrap();
    assert_eq!(out[i + 1], "PASS");
    assert_eq!(out[i + 2], "PLAY 1 CIN-027");
    assert_eq!(out[i + 3], "LEGAL END");
}

#[test]
fn trace_state_prints_after_accepted_actions_only() {
    let out = run(&format!("{BASE}TRACE state\nDECK A CIN-001\nDECK B CIN-001\nSTART\nB PASS\nA PASS\n"));
    assert_eq!(out.iter().filter(|l| *l == "STATE BEGIN").count(), 1);
}

#[test]
fn extra_database_exercises_relic_selectors() {
    let input = format!(
        "CARDS {}\nSEED 1\nOPENING 0\nSHUFFLE off\nSTART\nCARD EXT-004\n",
        data("extra.spire")
    );
    let out = cardgame::run_match(&input);
    assert!(out.contains("ability 1 resolve - (each (relics yours) (counters 1 that)) (ward 2 (relics yours))"));
}
