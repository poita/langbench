//! The typed card model: cards, abilities and the effect language (SPEC.md
//! sections 5 and 6), produced once by [`crate::database`] and then only read.

use std::rc::Rc;

/// An object id (`#7`). Oids start at 1.
pub type Oid = u32;
/// A Chain entry id (`~3`). Cids start at 1.
pub type Cid = u32;

/// One of the two players.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Player {
    A,
    B,
}

impl Player {
    /// Both players, A first.
    pub const BOTH: [Player; 2] = [Player::A, Player::B];

    /// The opponent.
    pub fn other(self) -> Player {
        match self {
            Player::A => Player::B,
            Player::B => Player::A,
        }
    }

    /// Index into per-player arrays.
    pub fn idx(self) -> usize {
        self as usize
    }

    /// `"A"` or `"B"`.
    pub fn name(self) -> &'static str {
        match self {
            Player::A => "A",
            Player::B => "B",
        }
    }
}

/// A card's type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CardType {
    Unit,
    Rite,
    Relic,
}

impl CardType {
    /// Parse `unit`, `rite` or `relic`.
    pub fn from_name(s: &str) -> Option<CardType> {
        match s {
            "unit" => Some(CardType::Unit),
            "rite" => Some(CardType::Rite),
            "relic" => Some(CardType::Relic),
            _ => None,
        }
    }

    /// The printed name.
    pub fn name(self) -> &'static str {
        match self {
            CardType::Unit => "unit",
            CardType::Rite => "rite",
            CardType::Relic => "relic",
        }
    }
}

/// The sixteen keywords (SPEC.md 16.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Keyword {
    Vanguard,
    Vigil,
    Riposte,
    Pierce,
    Ghostwalk,
    Skyhook,
    Venom,
    Siphon,
    Plating,
    Provoke,
    Spectral,
    Tenacity,
    Siegework,
    Shackled,
    Relentless,
    Swift,
}

const KEYWORD_NAMES: [(&str, Keyword); 16] = [
    ("vanguard", Keyword::Vanguard),
    ("vigil", Keyword::Vigil),
    ("riposte", Keyword::Riposte),
    ("pierce", Keyword::Pierce),
    ("ghostwalk", Keyword::Ghostwalk),
    ("skyhook", Keyword::Skyhook),
    ("venom", Keyword::Venom),
    ("siphon", Keyword::Siphon),
    ("plating", Keyword::Plating),
    ("provoke", Keyword::Provoke),
    ("spectral", Keyword::Spectral),
    ("tenacity", Keyword::Tenacity),
    ("siegework", Keyword::Siegework),
    ("shackled", Keyword::Shackled),
    ("relentless", Keyword::Relentless),
    ("swift", Keyword::Swift),
];

impl Keyword {
    /// Parse a keyword name.
    pub fn from_name(s: &str) -> Option<Keyword> {
        KEYWORD_NAMES.iter().find(|(n, _)| *n == s).map(|(_, k)| *k)
    }

    /// The keyword's name.
    pub fn name(self) -> &'static str {
        KEYWORD_NAMES[self as usize].0
    }

    /// Whether the keyword may be printed on a card of this type (SPEC.md 5.2).
    pub fn legal_on(self, t: CardType) -> bool {
        match t {
            CardType::Rite => self == Keyword::Swift,
            CardType::Relic => false,
            CardType::Unit => self != Keyword::Swift,
        }
    }
}

/// A keyword instance: `value` is only meaningful for `plating`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KwSpec {
    pub kw: Keyword,
    pub value: i64,
}

impl KwSpec {
    /// Rendering used by `GRANT` lines and `CARD` blocks (`plating:N`).
    pub fn render(&self) -> String {
        if self.kw == Keyword::Plating {
            format!("plating:{}", self.value)
        } else {
            self.kw.name().to_string()
        }
    }
}

/// A comparator (SPEC.md 6.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cmp {
    Le,
    Lt,
    Eq,
    Ge,
    Gt,
    Ne,
}

impl Cmp {
    /// Parse a comparator name.
    pub fn from_name(s: &str) -> Option<Cmp> {
        Some(match s {
            "le" => Cmp::Le,
            "lt" => Cmp::Lt,
            "eq" => Cmp::Eq,
            "ge" => Cmp::Ge,
            "gt" => Cmp::Gt,
            "ne" => Cmp::Ne,
            _ => return None,
        })
    }

    /// Compare `left` against `right`.
    pub fn test(self, left: i64, right: i64) -> bool {
        match self {
            Cmp::Le => left <= right,
            Cmp::Lt => left < right,
            Cmp::Eq => left == right,
            Cmp::Ge => left >= right,
            Cmp::Gt => left > right,
            Cmp::Ne => left != right,
        }
    }
}

/// `yours`, `theirs` or `all`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Yours,
    Theirs,
    All,
}

/// A card zone named by the `cards` selector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoneName {
    Hand,
    Ash,
    Vault,
    Rift,
}

/// An object filter (SPEC.md 6.5).
#[derive(Debug, Clone)]
pub enum Filter {
    Kw(Keyword),
    NoKw(Keyword),
    Tag(String),
    Type(CardType),
    Cost(Cmp, i64),
    Edge(Cmp, i64),
    Core(Cmp, i64),
    Wounded,
    Ready,
    Exhausted,
    Settling,
    Attacking,
    Blocking,
    Mine,
    Enemy,
    Other,
    Not(Box<Filter>),
}

/// An object selector (SPEC.md 6.3).
#[derive(Debug, Clone)]
pub enum Sel {
    SelfObj,
    It,
    That,
    /// `(t n)`, 1-based.
    Target(usize),
    Units(Scope, Vec<Filter>),
    Relics(Scope, Vec<Filter>),
    Cards(ZoneName, Scope, Vec<Filter>),
    RandomUnit(Scope, Vec<Filter>),
}

/// A player selector (SPEC.md 6.4).
#[derive(Debug, Clone)]
pub enum PSel {
    You,
    Foe,
    Both,
    Target(usize),
    OwnerOf(Box<Sel>),
}

/// A damage selector (SPEC.md 6.4.1).
#[derive(Debug, Clone)]
pub enum DSel {
    Player(PSel),
    Obj(Sel),
}

/// An amount (SPEC.md 6.6).
#[derive(Debug, Clone)]
pub enum Amt {
    Int(i64),
    Count(Sel),
    Hand(PSel),
    Ash(PSel),
    Vault(PSel),
    Edge(Sel),
    Core(Sel),
    Wounds(Sel),
}

/// A condition (SPEC.md 6.7).
#[derive(Debug, Clone)]
pub enum Cond {
    Count(Sel, Cmp, i64),
    Spire(PSel, Cmp, i64),
    Hand(PSel, Cmp, i64),
    Ash(PSel, Cmp, i64),
    Vault(PSel, Cmp, i64),
    Ember(PSel, Cmp, i64),
    MyTurn,
    And(Vec<Cond>),
    Or(Vec<Cond>),
    Not(Box<Cond>),
}

/// When a delayed trigger fires.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum When {
    TurnEnd,
    EndOfCombat,
    YourNextTurnStart,
}

impl When {
    /// Parse a `<when>` symbol.
    pub fn from_name(s: &str) -> Option<When> {
        Some(match s {
            "turn-end" => When::TurnEnd,
            "end-of-combat" => When::EndOfCombat,
            "your-next-turn-start" => When::YourNextTurnStart,
            _ => return None,
        })
    }

    /// The printed name.
    pub fn name(self) -> &'static str {
        match self {
            When::TurnEnd => "turn-end",
            When::EndOfCombat => "end-of-combat",
            When::YourNextTurnStart => "your-next-turn-start",
        }
    }
}

/// An effect (SPEC.md 6.8).
#[derive(Debug, Clone)]
pub enum Effect {
    Damage(Amt, DSel),
    Destroy(Sel),
    Sacrifice(Sel),
    Exile(Sel),
    Bounce(Sel),
    Draw(Amt, PSel),
    Discard(Amt, PSel),
    Mill(Amt, PSel),
    Spire(Amt, PSel),
    Ember(Amt, PSel),
    Cap(Amt, PSel),
    Modify(Amt, Amt, Sel),
    Setbody(Amt, Amt, Sel),
    Swapstats(Sel),
    Grant(KwSpec, Sel),
    Strip(Sel),
    Control(Sel),
    Counters(Amt, Sel),
    Ready(Sel),
    Exhaust(Sel),
    Doom(Sel),
    Ward(Amt, Sel),
    Shield(Amt, PSel),
    Summon(String, Amt, PSel),
    Conjure(String, Amt, PSel),
    Reanimate(Sel),
    Recall(Sel),
    /// `(negate (t n))`, holding the 1-based target index.
    Negate(usize),
    Dig(i64, Vec<Filter>, PSel),
    Delay(When, Rc<Vec<Effect>>),
    If(Cond, Vec<Effect>, Vec<Effect>),
    Each(Sel, Vec<Effect>),
    Repeat(Amt, Vec<Effect>),
    Nothing,
}

/// A card filter used by `cheaper` (SPEC.md 6.11).
#[derive(Debug, Clone)]
pub enum CardFilter {
    Type(CardType),
    Tag(String),
    Cost(Cmp, i64),
}

/// An aura static (SPEC.md 6.11).
#[derive(Debug, Clone)]
pub enum Static {
    Modify(Amt, Amt, Sel),
    Setbody(Amt, Amt, Sel),
    Swapstats(Sel),
    Grant(KwSpec, Sel),
    Cheaper(i64, Vec<CardFilter>),
    When(Cond, Vec<Static>),
}

/// An activated-ability cost item (SPEC.md 6.10).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CostItem {
    Ember(i64),
    Spire(i64),
    Discard(i64),
    Exhaust,
    SacSelf,
    Counters(i64),
    Once,
}

/// A target specification (SPEC.md 12.1).
#[derive(Debug, Clone)]
pub enum TSpec {
    Unit(Vec<Filter>),
    Relic(Vec<Filter>),
    Any(Vec<Filter>),
    Player,
    Chained,
    AshCard(Vec<Filter>),
}

macro_rules! events {
    ($( $variant:ident => $name:expr ),* $(,)?) => {
        /// A trigger event (SPEC.md 13.1).
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum Event { $( $variant ),* }

        impl Event {
            /// Every event.
            pub const ALL: &'static [Event] = &[ $( Event::$variant ),* ];

            /// Parse an event name.
            pub fn from_name(s: &str) -> Option<Event> {
                match s { $( $name => Some(Event::$variant), )* _ => None }
            }

            /// The printed name.
            pub fn name(self) -> &'static str {
                match self { $( Event::$variant => $name ),* }
            }
        }
    };
}

events! {
    Arrive => "arrive",
    Leave => "leave",
    Dies => "dies",
    AllyArrive => "ally-arrive",
    EnemyArrive => "enemy-arrive",
    AllyDies => "ally-dies",
    EnemyDies => "enemy-dies",
    TurnStart => "turn-start",
    YourTurnStart => "your-turn-start",
    TurnEnd => "turn-end",
    YourTurnEnd => "your-turn-end",
    Attacks => "attacks",
    Blocks => "blocks",
    Blocked => "blocked",
    Unblocked => "unblocked",
    Damaged => "damaged",
    DealsDamage => "deals-damage",
    YouPlayRite => "you-play-rite",
    EnemyPlaysRite => "enemy-plays-rite",
    YouDraw => "you-draw",
    SpireLoss => "spire-loss",
    EnemySpireLoss => "enemy-spire-loss",
    EndOfCombat => "end-of-combat",
}

/// Which clause an ability came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AbilityKind {
    Resolve,
    On,
    Act,
    Aura,
}

/// One numbered ability of a card (SPEC.md 5.3).
#[derive(Debug, Clone)]
pub struct Ability {
    pub kind: AbilityKind,
    /// The trigger event, for `on` abilities.
    pub event: Option<Event>,
    /// Cost items, for `act` abilities.
    pub cost: Vec<CostItem>,
    /// Target specifications.
    pub targets: Rc<Vec<TSpec>>,
    /// Effects, for `resolve`, `on` and `act`.
    pub effects: Rc<Vec<Effect>>,
    /// Statics, for `aura`.
    pub statics: Vec<Static>,
    /// The canonical rendering printed by the `CARD` directive.
    pub rendered: String,
}

/// A card definition.
#[derive(Debug, Clone)]
pub struct Card {
    pub id: String,
    pub name: String,
    pub ctype: CardType,
    pub cost: i64,
    pub edge: i64,
    pub core: i64,
    pub tags: Vec<String>,
    pub keywords: Vec<KwSpec>,
    pub text: Option<String>,
    /// Abilities in ability-number order; ability `n` is `abilities[n - 1]`.
    pub abilities: Vec<Ability>,
    /// Bit set of the events some `on` ability listens to.
    pub event_mask: u32,
}

impl Card {
    /// Whether any `on` ability listens to `ev`.
    pub fn listens(&self, ev: Event) -> bool {
        self.event_mask & (1u32 << ev as u32) != 0
    }

    /// Whether the printed keywords include `kw`.
    pub fn has_printed(&self, kw: Keyword) -> bool {
        self.keywords.iter().any(|k| k.kw == kw)
    }
}
