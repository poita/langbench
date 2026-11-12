//! Core engine data: objects, players, the Chain, continuous-effect records,
//! and the [`Engine`] struct that owns them (SPEC.md section 7).

use std::collections::VecDeque;
use std::rc::Rc;

use crate::database::Database;
use crate::matchfile::Trace;
use crate::model::*;
use crate::rng::Rng;

/// Where an object currently is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Zone {
    Vault,
    Hand,
    Field,
    Ash,
    Rift,
    /// On the Chain, or freshly created and not yet placed.
    Limbo,
}

impl Zone {
    /// The name used in `EXILE` lines.
    pub fn name(self) -> &'static str {
        match self {
            Zone::Vault => "vault",
            Zone::Hand => "hand",
            Zone::Field => "field",
            Zone::Ash => "ash",
            Zone::Rift => "rift",
            Zone::Limbo => "limbo",
        }
    }
}

/// A set of keyword instances (SPEC.md 16).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct KwSet {
    bits: u32,
    plating_count: u32,
    plating_sum: i64,
}

impl KwSet {
    /// Build from printed keywords.
    pub fn from_specs(specs: &[KwSpec]) -> KwSet {
        let mut s = KwSet::default();
        for k in specs {
            s.add(*k);
        }
        s
    }

    /// Add a keyword instance.
    pub fn add(&mut self, k: KwSpec) {
        if k.kw == Keyword::Plating {
            self.plating_count += 1;
            self.plating_sum += k.value;
        } else {
            self.bits |= 1 << k.kw as u32;
        }
    }

    /// Remove every instance.
    pub fn clear(&mut self) {
        *self = KwSet::default();
    }

    /// Whether the keyword is present.
    pub fn has(&self, kw: Keyword) -> bool {
        if kw == Keyword::Plating {
            self.plating_count > 0
        } else {
            self.bits & (1 << kw as u32) != 0
        }
    }

    /// The sum of every plating instance.
    pub fn plating(&self) -> i64 {
        self.plating_sum
    }

    /// Rendered keywords in ascending order (`plating:N` for plating).
    pub fn render(&self) -> Vec<String> {
        let mut v: Vec<String> = Vec::new();
        for (i, _) in KEYWORD_ORDER.iter().enumerate() {
            let kw = KEYWORD_ORDER[i];
            if kw == Keyword::Plating {
                if self.plating_count > 0 {
                    v.push(format!("plating:{}", self.plating_sum));
                }
            } else if self.has(kw) {
                v.push(kw.name().to_string());
            }
        }
        v.sort();
        v
    }
}

const KEYWORD_ORDER: [Keyword; 16] = [
    Keyword::Vanguard,
    Keyword::Vigil,
    Keyword::Riposte,
    Keyword::Pierce,
    Keyword::Ghostwalk,
    Keyword::Skyhook,
    Keyword::Venom,
    Keyword::Siphon,
    Keyword::Plating,
    Keyword::Provoke,
    Keyword::Spectral,
    Keyword::Tenacity,
    Keyword::Siegework,
    Keyword::Shackled,
    Keyword::Relentless,
    Keyword::Swift,
];

/// Per-object state that exists only while on the Field (SPEC.md 7.5).
#[derive(Debug, Clone, Default)]
pub struct FieldState {
    pub exhausted: bool,
    pub wounds: i64,
    pub counters: i64,
    pub ward: i64,
    pub doomed: bool,
    pub since: u64,
    pub attacking: bool,
    /// The attacker this unit blocks.
    pub blocking: Option<Oid>,
    /// Blockers of this attacker, in canonical order.
    pub blockers: Vec<Oid>,
    pub blocked: bool,
    pub tenacity_used: bool,
    pub once_used: Vec<usize>,
}

/// Derived (current) characteristics of a Field object (SPEC.md 14.3).
#[derive(Debug, Clone, Copy)]
pub struct Current {
    pub ctrl: Player,
    pub edge: i64,
    pub core: i64,
    pub kw: KwSet,
    pub stripped: bool,
}

/// A card instance.
#[derive(Debug)]
pub struct Obj {
    pub card: Rc<Card>,
    pub owner: Player,
    pub zone: Zone,
    pub ts: u64,
    /// Controller when it last left the Field (owner if it never was there).
    pub last_ctrl: Player,
    pub base_ctrl: Player,
    pub fs: FieldState,
    pub cur: Current,
}

impl Obj {
    pub fn is_unit(&self) -> bool {
        self.card.ctype == CardType::Unit
    }
}

/// Why a player lost.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Spire,
    Vault,
    Concede,
}

impl Reason {
    pub fn name(self) -> &'static str {
        match self {
            Reason::Spire => "spire",
            Reason::Vault => "vault",
            Reason::Concede => "concede",
        }
    }
}

/// The final outcome of a match.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MatchResult {
    /// `None` is a draw.
    pub winner: Option<Player>,
    /// The reason word printed on the `RESULT` line.
    pub reason: &'static str,
}

/// One player's numbers and private zones.
#[derive(Debug)]
pub struct PlayerState {
    pub spire: i64,
    pub ember: i64,
    pub cap: i64,
    pub shield: i64,
    pub vault: VecDeque<Oid>,
    pub hand: Vec<Oid>,
    pub ash: Vec<Oid>,
    pub rift: Vec<Oid>,
    pub lost: Option<Reason>,
}

impl PlayerState {
    pub fn new(spire: i64, cap: i64) -> PlayerState {
        PlayerState {
            spire,
            ember: 0,
            cap,
            shield: 0,
            vault: VecDeque::new(),
            hand: Vec::new(),
            ash: Vec::new(),
            rift: Vec::new(),
            lost: None,
        }
    }
}

/// A target: a player, an object, or a Chain entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tgt {
    Player(Player),
    Obj(Oid),
    Entry(Cid),
}

/// A target slot of a Chain entry, with its "removed" mark (SPEC.md 11.6).
#[derive(Debug, Clone, Copy)]
pub struct TSlot {
    pub tgt: Tgt,
    pub removed: bool,
}

/// The trigger subject `it` (SPEC.md 13.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Subject {
    None,
    Obj(Oid),
    Player(Player),
}

/// What a Chain entry is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    Rite,
    Unit,
    Relic,
    Ability,
    Trigger,
}

impl EntryKind {
    pub fn name(self) -> &'static str {
        match self {
            EntryKind::Rite => "rite",
            EntryKind::Unit => "unit",
            EntryKind::Relic => "relic",
            EntryKind::Ability => "ability",
            EntryKind::Trigger => "trigger",
        }
    }
}

/// A delayed-trigger record (SPEC.md 13.5).
#[derive(Debug)]
pub struct Delayed {
    pub ts: u64,
    pub ctrl: Player,
    pub src: Oid,
    pub when: When,
    pub targets: Vec<Tgt>,
    pub specs: Rc<Vec<TSpec>>,
    pub effects: Rc<Vec<Effect>>,
}

/// An entry on the Chain.
#[derive(Debug, Clone)]
pub struct Entry {
    pub cid: Cid,
    pub kind: EntryKind,
    pub ctrl: Player,
    pub src: Oid,
    pub idx: usize,
    pub targets: Vec<TSlot>,
    pub specs: Rc<Vec<TSpec>>,
    pub subject: Subject,
    pub delayed: Option<Rc<Delayed>>,
}

/// A trigger collected but not yet pushed (SPEC.md 13.3).
#[derive(Debug, Clone)]
pub struct Pending {
    pub ctrl: Player,
    pub src: Oid,
    pub idx: usize,
    pub ts: u64,
    pub subject: Subject,
    pub delayed: Option<Rc<Delayed>>,
}

/// The kind of a continuous-effect record.
#[derive(Debug, Clone)]
pub enum RecKind {
    Modify(i64, i64),
    Setbody(i64, i64),
    Swap,
    Grant(KwSpec),
    Strip,
    Control,
    /// An aura record: `ability` is the 0-based index into the card's abilities.
    Aura { ability: usize },
}

/// A continuous-effect record (SPEC.md 14.1).
#[derive(Debug, Clone)]
pub struct Record {
    pub eid: u64,
    pub ts: u64,
    pub ctrl: Player,
    pub src: Oid,
    pub kind: RecKind,
    /// Affected objects of a discrete record.
    pub affected: Vec<Oid>,
}

/// One evaluated leaf static of an aura record (cached by derivation).
#[derive(Debug, Clone)]
pub enum LeafKind {
    Modify(i64, i64),
    Setbody(i64, i64),
    Swap,
    Grant(KwSpec),
    Cheaper(i64, Vec<CardFilter>),
}

/// An evaluated leaf of an aura static.
#[derive(Debug, Clone)]
pub struct Leaf {
    pub kind: LeafKind,
    pub active: bool,
    pub affected: Vec<Oid>,
}

/// The evaluation of one aura record at the last derivation.
#[derive(Debug, Clone)]
pub struct AuraEval {
    pub ctrl: Player,
    pub leaves: Vec<Leaf>,
}

/// The phases and steps of a turn (SPEC.md section 9).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Dawn,
    Draw,
    Main1,
    ClashAttack,
    ClashBlock,
    ClashRiposte,
    ClashDamage,
    ClashEnd,
    Main2,
    DuskTrigger,
    DuskDiscard,
    DuskCleanup,
}

impl Step {
    pub fn name(self) -> &'static str {
        match self {
            Step::Dawn => "dawn",
            Step::Draw => "draw",
            Step::Main1 => "main1",
            Step::ClashAttack => "clash-attack",
            Step::ClashBlock => "clash-block",
            Step::ClashRiposte => "clash-riposte",
            Step::ClashDamage => "clash-damage",
            Step::ClashEnd => "clash-end",
            Step::Main2 => "main2",
            Step::DuskTrigger => "dusk-trigger",
            Step::DuskDiscard => "dusk-discard",
            Step::DuskCleanup => "dusk-cleanup",
        }
    }
}

/// What the engine is waiting for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Priority,
    Attackers,
    Blockers,
}

impl Decision {
    pub fn name(self) -> &'static str {
        match self {
            Decision::Priority => "priority",
            Decision::Attackers => "attackers",
            Decision::Blockers => "blockers",
        }
    }
}

/// What the run loop does next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cont {
    TurnStart,
    Enter(Step),
    Waiting,
}

/// Fixed configuration from the setup block.
#[derive(Debug, Clone)]
pub struct Config {
    pub maxcap: i64,
    pub handmax: usize,
    pub turnlimit: u64,
    pub trace: Trace,
}

/// The whole game: state plus the resumable rules engine.
///
/// Rules processing is split over several modules, each adding an `impl
/// Engine` block: `derive` (layers), `eval` (selectors, amounts), `procedures`
/// (section 17), `triggers`, `chain`, `effects`, `turn`, `combat`, `legal`
/// and `dump`.
pub struct Engine {
    pub(crate) db: Rc<Database>,
    pub(crate) cfg: Config,
    pub(crate) objs: Vec<Obj>,
    pub(crate) players: [PlayerState; 2],
    /// Field objects in canonical order (entry order is timestamp order).
    pub(crate) field: Vec<Oid>,
    pub(crate) chain: Vec<Entry>,
    pub(crate) records: Vec<Record>,
    pub(crate) delayed: Vec<Rc<Delayed>>,
    pub(crate) pending: Vec<Pending>,
    pub(crate) next_ts: u64,
    pub(crate) next_cid: Cid,
    pub(crate) next_eid: u64,
    pub(crate) turn: u64,
    pub(crate) active: Player,
    pub(crate) step: Step,
    pub(crate) rng: Rng,
    pub(crate) out: String,
    pub(crate) seq: u64,
    pub(crate) result: Option<MatchResult>,
    pub(crate) cont: Cont,
    pub(crate) decision: Option<(Player, Decision)>,
    /// The step whose priority round is running.
    pub(crate) round_step: Step,
    pub(crate) passes: u8,
    pub(crate) holder: Player,
    pub(crate) dirty: bool,
    pub(crate) aura_evals: Vec<AuraEval>,
    pub(crate) in_derive: bool,
    /// Units that dealt combat damage in the riposte sub-step.
    pub(crate) riposte_dealt: Vec<Oid>,
    /// Whether draws and entries collect triggers (off during setup).
    pub(crate) triggers_on: bool,
}

impl Engine {
    /// The object with this oid.
    pub(crate) fn obj(&self, o: Oid) -> &Obj {
        &self.objs[o as usize - 1]
    }

    pub(crate) fn obj_mut(&mut self, o: Oid) -> &mut Obj {
        &mut self.objs[o as usize - 1]
    }

    /// Whether `o` names an existing object.
    pub(crate) fn exists(&self, o: Oid) -> bool {
        o >= 1 && (o as usize) <= self.objs.len()
    }

    pub(crate) fn on_field(&self, o: Oid) -> bool {
        self.obj(o).zone == Zone::Field
    }

    /// Mark derived data stale; call after any mutation derivation could see.
    pub(crate) fn touch(&mut self) {
        self.dirty = true;
    }

    /// Append an event line with the next sequence number.
    pub(crate) fn emit(&mut self, text: impl AsRef<str>) {
        self.seq += 1;
        self.out.push_str(&self.seq.to_string());
        self.out.push(' ');
        self.out.push_str(text.as_ref());
        self.out.push('\n');
    }

    /// Append a non-event line (an `ERR` line or a block line).
    pub(crate) fn raw(&mut self, text: impl AsRef<str>) {
        self.out.push_str(text.as_ref());
        self.out.push('\n');
    }

    /// Whether the match has ended.
    pub fn is_over(&self) -> bool {
        self.result.is_some()
    }

    /// The match result, once ended.
    pub fn result(&self) -> Option<MatchResult> {
        self.result
    }

    /// Take everything written so far.
    pub fn take_output(&mut self) -> String {
        std::mem::take(&mut self.out)
    }

    pub(crate) fn render_tgt(&self, t: Tgt) -> String {
        match t {
            Tgt::Player(p) => p.name().to_string(),
            Tgt::Obj(o) => format!("#{o}"),
            Tgt::Entry(c) => format!("~{c}"),
        }
    }

    /// The target key of SPEC.md 12.4.
    pub(crate) fn tgt_key(&self, t: Tgt) -> (u8, u64, u64) {
        match t {
            Tgt::Player(p) => (0, p.idx() as u64, 0),
            Tgt::Obj(o) => (1, self.obj(o).ts, o as u64),
            Tgt::Entry(c) => (2, c as u64, 0),
        }
    }

    /// Canonical ordering key of an object.
    pub(crate) fn ckey(&self, o: Oid) -> (u64, Oid) {
        (self.obj(o).ts, o)
    }

    pub(crate) fn sort_canonical(&self, v: &mut [Oid]) {
        v.sort_by_key(|&o| self.ckey(o));
    }

    pub(crate) fn new_ts(&mut self) -> u64 {
        let t = self.next_ts;
        self.next_ts += 1;
        t
    }
}
