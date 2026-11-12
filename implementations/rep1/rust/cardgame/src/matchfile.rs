//! Match-file parsing: the setup block (SPEC.md 4.1) and script lines (4.2).

use std::fmt;

use crate::model::Player;

/// A setup-block violation; the CLI prints `FATAL bad-setup`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupError(pub String);

impl fmt::Display for SetupError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "bad setup: {}", self.0)
    }
}

impl std::error::Error for SetupError {}

/// What `TRACE` prints after every accepted action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trace {
    None,
    Legal,
    State,
}

/// A setup zone line kind, in the order setup processes them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetupZone {
    Deck = 0,
    Hand = 1,
    Field = 2,
    Ash = 3,
    Rift = 4,
}

/// The parsed setup block.
#[derive(Debug, Clone)]
pub struct Setup {
    pub cards_path: String,
    pub seed: u64,
    pub spire: i64,
    pub opening: usize,
    pub maxcap: i64,
    pub handmax: usize,
    pub turnlimit: u64,
    pub first: Player,
    pub shuffle: bool,
    pub trace: Trace,
    pub cap: [i64; 2],
    /// `zones[player][zone]` lists card ids with `*n` already expanded.
    pub zones: [[Vec<String>; 5]; 2],
}

/// Parse a plain decimal number (digits only, leading zeros allowed) into
/// `u64`, or `None` if it is malformed or does not fit.
pub fn parse_decimal(s: &str) -> Option<u64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut v: u64 = 0;
    for b in s.bytes() {
        v = v.checked_mul(10)?.checked_add(u64::from(b - b'0'))?;
    }
    Some(v)
}

fn words(line: &str) -> Vec<&str> {
    line.split([' ', '\t']).filter(|w| !w.is_empty()).collect()
}

fn is_comment(line: &str) -> bool {
    let t = line.trim_matches([' ', '\t']);
    t.is_empty() || t.starts_with('#')
}

/// Strip a single trailing `\r`, as the I/O contract requires.
fn strip_cr(line: &str) -> &str {
    line.strip_suffix('\r').unwrap_or(line)
}

/// Split a match file into lines (without terminators, `\r` stripped).
pub fn split_lines(input: &str) -> Vec<&str> {
    let mut lines: Vec<&str> = input.split('\n').map(strip_cr).collect();
    if input.ends_with('\n') || input.is_empty() {
        lines.pop();
    }
    lines
}

fn bad<T>(msg: &str) -> Result<T, SetupError> {
    Err(SetupError(msg.to_string()))
}

fn number(w: &[&str], lo: u64, hi: u64) -> Result<u64, SetupError> {
    if w.len() != 2 {
        return bad("wrong number of words");
    }
    match parse_decimal(w[1]) {
        Some(n) if (lo..=hi).contains(&n) => Ok(n),
        _ => bad("number out of range"),
    }
}

fn dup<T>(slot: &Option<T>) -> Result<(), SetupError> {
    if slot.is_some() {
        bad("duplicate setup line")
    } else {
        Ok(())
    }
}

fn player_word(w: &str) -> Result<Player, SetupError> {
    match w {
        "A" => Ok(Player::A),
        "B" => Ok(Player::B),
        _ => bad("expected A or B"),
    }
}

/// Parse the setup block. Returns the setup and the index (0-based, into
/// `lines`) of the first script line, i.e. the line after `START`.
pub fn parse_setup(lines: &[&str]) -> Result<(Setup, usize), SetupError> {
    let mut cards = None;
    let mut seed = None;
    let mut spire = None;
    let mut opening = None;
    let mut maxcap = None;
    let mut handmax = None;
    let mut turnlimit = None;
    let mut first = None;
    let mut shuffle = None;
    let mut trace = None;
    let mut cap: [Option<i64>; 2] = [None, None];
    let mut zones: [[Vec<String>; 5]; 2] = Default::default();
    let mut start = None;

    for (i, line) in lines.iter().enumerate() {
        if is_comment(line) {
            continue;
        }
        let w = words(line);
        match w[0] {
            "START" => {
                if w.len() != 1 {
                    return bad("START takes no argument");
                }
                start = Some(i + 1);
                break;
            }
            "CARDS" => {
                dup(&cards)?;
                if w.len() != 2 {
                    return bad("CARDS needs one path");
                }
                cards = Some(w[1].to_string());
            }
            "SEED" => {
                dup(&seed)?;
                seed = Some(number(&w, 0, u64::MAX)?);
            }
            "SPIRE" => {
                dup(&spire)?;
                spire = Some(number(&w, 1, 1_000_000)? as i64);
            }
            "OPENING" => {
                dup(&opening)?;
                opening = Some(number(&w, 0, 20)? as usize);
            }
            "MAXCAP" => {
                dup(&maxcap)?;
                maxcap = Some(number(&w, 1, 100)? as i64);
            }
            "HANDMAX" => {
                dup(&handmax)?;
                handmax = Some(number(&w, 0, 100)? as usize);
            }
            "TURNLIMIT" => {
                dup(&turnlimit)?;
                turnlimit = Some(number(&w, 1, 100_000)?);
            }
            "FIRST" => {
                dup(&first)?;
                if w.len() != 2 {
                    return bad("FIRST needs a player");
                }
                first = Some(player_word(w[1])?);
            }
            "SHUFFLE" => {
                dup(&shuffle)?;
                if w.len() != 2 {
                    return bad("SHUFFLE needs on/off");
                }
                shuffle = Some(match w[1] {
                    "on" => true,
                    "off" => false,
                    _ => return bad("SHUFFLE needs on/off"),
                });
            }
            "TRACE" => {
                dup(&trace)?;
                if w.len() != 2 {
                    return bad("TRACE needs a mode");
                }
                trace = Some(match w[1] {
                    "none" => Trace::None,
                    "legal" => Trace::Legal,
                    "state" => Trace::State,
                    _ => return bad("bad TRACE mode"),
                });
            }
            "CAP" => {
                if w.len() != 3 {
                    return bad("CAP needs a player and a number");
                }
                let p = player_word(w[1])?;
                dup(&cap[p.idx()])?;
                cap[p.idx()] = Some(number(&[w[0], w[2]], 0, 100)? as i64);
            }
            "DECK" | "HAND" | "FIELD" | "ASH" | "RIFT" => {
                if w.len() < 3 {
                    return bad("zone line needs entries");
                }
                let p = player_word(w[1])?;
                let z = match w[0] {
                    "DECK" => SetupZone::Deck,
                    "HAND" => SetupZone::Hand,
                    "FIELD" => SetupZone::Field,
                    "ASH" => SetupZone::Ash,
                    _ => SetupZone::Rift,
                };
                for entry in &w[2..] {
                    let (id, count) = match entry.split_once('*') {
                        None => (*entry, 1u64),
                        Some((id, c)) => match parse_decimal(c) {
                            Some(n) if (1..=1000).contains(&n) => (id, n),
                            _ => return bad("bad entry count"),
                        },
                    };
                    if id.is_empty() || id.contains('*') {
                        return bad("bad entry");
                    }
                    for _ in 0..count {
                        zones[p.idx()][z as usize].push(id.to_string());
                    }
                }
            }
            _ => return bad("unknown setup word"),
        }
    }

    let Some(start) = start else {
        return bad("missing START");
    };
    let (Some(cards), Some(seed)) = (cards, seed) else {
        return bad("missing CARDS or SEED");
    };
    Ok((
        Setup {
            cards_path: cards,
            seed,
            spire: spire.unwrap_or(25),
            opening: opening.unwrap_or(5),
            maxcap: maxcap.unwrap_or(10),
            handmax: handmax.unwrap_or(7),
            turnlimit: turnlimit.unwrap_or(200),
            first: first.unwrap_or(Player::A),
            shuffle: shuffle.unwrap_or(true),
            trace: trace.unwrap_or(Trace::None),
            cap: [cap[0].unwrap_or(0), cap[1].unwrap_or(0)],
            zones,
        },
        start,
    ))
}

/// A target token as written in a script line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetToken {
    Player(Player),
    Object(u64),
    Entry(u64),
}

/// A player action (SPEC.md 4.2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Pass,
    Concede,
    Play { pos: u64, targets: Vec<TargetToken> },
    Act { oid: u64, index: u64, targets: Vec<TargetToken> },
    Attack(Vec<u64>),
    Block(Vec<(u64, u64)>),
}

/// One script line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Action(Player, Action),
    Dump,
    Legal,
    Vault,
    Card(String),
}

fn objref(w: &str) -> Option<u64> {
    parse_decimal(w.strip_prefix('#')?)
}

fn target_token(w: &str) -> Option<TargetToken> {
    match w {
        "A" => Some(TargetToken::Player(Player::A)),
        "B" => Some(TargetToken::Player(Player::B)),
        _ => {
            if let Some(r) = w.strip_prefix('#') {
                parse_decimal(r).map(TargetToken::Object)
            } else if let Some(r) = w.strip_prefix('~') {
                parse_decimal(r).map(TargetToken::Entry)
            } else {
                None
            }
        }
    }
}

/// Parse one non-comment script line; `None` means `bad-syntax`.
pub fn parse_command(line: &str) -> Option<Command> {
    let w = words(line);
    let first = *w.first()?;
    match first {
        "DUMP" => return (w.len() == 1).then_some(Command::Dump),
        "LEGAL" => return (w.len() == 1).then_some(Command::Legal),
        "VAULT" => return (w.len() == 1).then_some(Command::Vault),
        "CARD" => return (w.len() == 2).then(|| Command::Card(w[1].to_string())),
        _ => {}
    }
    let player = match first {
        "A" => Player::A,
        "B" => Player::B,
        _ => return None,
    };
    let word = *w.get(1)?;
    let action = match word {
        "PASS" => (w.len() == 2).then_some(Action::Pass)?,
        "CONCEDE" => (w.len() == 2).then_some(Action::Concede)?,
        "PLAY" => {
            if w.len() < 3 {
                return None;
            }
            let pos = parse_decimal(w[2])?;
            let targets = w[3..]
                .iter()
                .map(|t| target_token(t))
                .collect::<Option<Vec<_>>>()?;
            Action::Play { pos, targets }
        }
        "ACT" => {
            if w.len() < 4 {
                return None;
            }
            let oid = objref(w[2])?;
            let index = parse_decimal(w[3])?;
            let targets = w[4..]
                .iter()
                .map(|t| target_token(t))
                .collect::<Option<Vec<_>>>()?;
            Action::Act { oid, index, targets }
        }
        "ATTACK" => Action::Attack(w[2..].iter().map(|t| objref(t)).collect::<Option<Vec<_>>>()?),
        "BLOCK" => {
            let mut pairs = Vec::new();
            for t in &w[2..] {
                let (b, a) = t.split_once(':')?;
                pairs.push((objref(b)?, objref(a)?));
            }
            Action::Block(pairs)
        }
        _ => return None,
    };
    Some(Command::Action(player, action))
}

/// Whether a line is a comment line (ignored everywhere).
pub fn is_comment_line(line: &str) -> bool {
    is_comment(line)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup(text: &str) -> Result<(Setup, usize), SetupError> {
        let lines = split_lines(text);
        parse_setup(&lines)
    }

    #[test]
    fn defaults_and_entries() {
        let (s, start) = setup(
            "CARDS x.spire\n# c\nSEED 007\nDECK A AAA-001*2 BBB-002\nDECK A CCC-003\nSTART\nA PASS\n",
        )
        .unwrap();
        assert_eq!(start, 6);
        assert_eq!(s.seed, 7);
        assert_eq!(s.spire, 25);
        assert_eq!(s.opening, 5);
        assert_eq!(
            s.zones[0][SetupZone::Deck as usize],
            vec!["AAA-001", "AAA-001", "BBB-002", "CCC-003"]
        );
    }

    #[test]
    fn rejects_bad_setup() {
        for t in [
            "SEED 1\nSTART\n",
            "CARDS x\nSTART\n",
            "CARDS x\nSEED 1\n",
            "CARDS x\nSEED 1\nSEED 2\nSTART\n",
            "CARDS x\nSEED -1\nSTART\n",
            "CARDS x\nSEED 1\nSPIRE 1000001\nSTART\n",
            "CARDS x\nSEED 1\nTRACE all\nSTART\n",
            "CARDS x\nSEED 1\nDECK A X*1001\nSTART\n",
            "CARDS x\nSEED 1\nDECK A X*0\nSTART\n",
            "CARDS x\nSEED 1\nSTART now\n",
            "CARDS x\nSEED 1\nFOO\nSTART\n",
            "CARDS x\nSEED 18446744073709551616\nSTART\n",
        ] {
            assert!(setup(t).is_err(), "accepted: {t:?}");
        }
        assert!(setup("CARDS x\nSEED 18446744073709551615\nCAP A 1\nCAP B 2\nSTART\n").is_ok());
    }

    #[test]
    fn commands() {
        assert_eq!(
            parse_command("A PLAY 02 #7 B ~3"),
            Some(Command::Action(
                Player::A,
                Action::Play {
                    pos: 2,
                    targets: vec![
                        TargetToken::Object(7),
                        TargetToken::Player(Player::B),
                        TargetToken::Entry(3)
                    ]
                }
            ))
        );
        assert_eq!(
            parse_command("B BLOCK #4:#2 #5:#2"),
            Some(Command::Action(Player::B, Action::Block(vec![(4, 2), (5, 2)])))
        );
        assert_eq!(parse_command("CARD ZZZ-999"), Some(Command::Card("ZZZ-999".into())));
        for bad in [
            "X PASS", "A", "A PASS x", "A PLAY", "A PLAY -1", "A ATTACK 3", "DUMP x", "CARD",
            "CARD a b", "A BLOCK #1", "A PLAY 99999999999999999999",
        ] {
            assert_eq!(parse_command(bad), None, "accepted: {bad}");
        }
    }
}
