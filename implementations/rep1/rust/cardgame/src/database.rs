//! Card database loading and validation (SPEC.md section 5).
//!
//! The text is read by [`crate::sexpr`], then every card is checked against
//! the grammar and turned into the typed model of [`crate::model`]. Any
//! violation yields a [`DatabaseError`], which the CLI reports as
//! `FATAL bad-database`.

use std::collections::HashMap;
use std::fmt;
use std::rc::Rc;

use crate::model::*;
use crate::sexpr::{self, Sexpr};

/// Why a card database was rejected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DatabaseError(pub String);

impl fmt::Display for DatabaseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid card database: {}", self.0)
    }
}

impl std::error::Error for DatabaseError {}

type R<T> = Result<T, DatabaseError>;

fn err<T>(msg: impl Into<String>) -> R<T> {
    Err(DatabaseError(msg.into()))
}

/// A validated set of card definitions.
#[derive(Debug, Clone, Default)]
pub struct Database {
    cards: Vec<Rc<Card>>,
    index: HashMap<String, usize>,
}

impl Database {
    /// Parse and validate database text.
    pub fn parse(text: &str) -> Result<Database, DatabaseError> {
        let forms = sexpr::parse(text).map_err(|e| DatabaseError(e.to_string()))?;
        let mut db = Database::default();
        for form in &forms {
            let card = parse_card(form)?;
            if db.index.contains_key(&card.id) {
                return err(format!("duplicate card id {}", card.id));
            }
            db.index.insert(card.id.clone(), db.cards.len());
            db.cards.push(Rc::new(card));
        }
        db.check_references()?;
        Ok(db)
    }

    /// Read, parse and validate a database file.
    pub fn load(path: &str) -> Result<Database, DatabaseError> {
        let bytes = std::fs::read(path).map_err(|e| DatabaseError(format!("{path}: {e}")))?;
        let text = String::from_utf8(bytes)
            .map_err(|_| DatabaseError(format!("{path}: not valid UTF-8")))?;
        Database::parse(&text)
    }

    /// Look a card up by id.
    pub fn get(&self, id: &str) -> Option<&Rc<Card>> {
        self.index.get(id).map(|&i| &self.cards[i])
    }

    /// Number of cards defined.
    pub fn len(&self) -> usize {
        self.cards.len()
    }

    /// Whether the database defines no cards.
    pub fn is_empty(&self) -> bool {
        self.cards.is_empty()
    }

    /// All cards, in file order.
    pub fn cards(&self) -> &[Rc<Card>] {
        &self.cards
    }

    fn check_references(&self) -> R<()> {
        for card in &self.cards {
            for ab in &card.abilities {
                check_effects(self, &ab.effects)?;
            }
        }
        Ok(())
    }
}

fn check_effects(db: &Database, effects: &[Effect]) -> R<()> {
    for e in effects {
        match e {
            Effect::Summon(id, _, _) => match db.get(id) {
                None => return err(format!("summon of unknown card {id}")),
                Some(c) if c.ctype == CardType::Rite => {
                    return err(format!("summon of rite {id}"))
                }
                _ => {}
            },
            Effect::Conjure(id, _, _) => {
                if db.get(id).is_none() {
                    return err(format!("conjure of unknown card {id}"));
                }
            }
            Effect::Delay(_, inner) => check_effects(db, inner)?,
            Effect::If(_, a, b) => {
                check_effects(db, a)?;
                check_effects(db, b)?;
            }
            Effect::Each(_, inner) | Effect::Repeat(_, inner) => check_effects(db, inner)?,
            _ => {}
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Helpers over s-expressions
// ---------------------------------------------------------------------------

fn is_card_id(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 7
        && b[..3].iter().all(|c| c.is_ascii_uppercase())
        && b[3] == b'-'
        && b[4..].iter().all(|c| c.is_ascii_digit())
}

/// Split a list form into its head symbol and arguments.
fn form(s: &Sexpr) -> R<(&str, &[Sexpr])> {
    match s {
        Sexpr::List(items) => match items.split_first() {
            Some((Sexpr::Sym(h), rest)) => Ok((h.as_str(), rest)),
            _ => err("expected a form starting with a symbol"),
        },
        _ => err("expected a list"),
    }
}

fn int(s: &Sexpr) -> R<i64> {
    s.as_int().map_or_else(|| err("expected an integer"), Ok)
}

fn sym(s: &Sexpr) -> R<&str> {
    s.as_sym().map_or_else(|| err("expected a symbol"), Ok)
}

fn arity(args: &[Sexpr], n: usize) -> R<()> {
    if args.len() == n {
        Ok(())
    } else {
        err("wrong number of arguments")
    }
}

// ---------------------------------------------------------------------------
// Selectors, filters, amounts, conditions
// ---------------------------------------------------------------------------

fn parse_scope(s: &Sexpr) -> R<Scope> {
    match sym(s)? {
        "yours" => Ok(Scope::Yours),
        "theirs" => Ok(Scope::Theirs),
        "all" => Ok(Scope::All),
        other => err(format!("bad scope {other}")),
    }
}

fn parse_cmp(s: &Sexpr) -> R<Cmp> {
    Cmp::from_name(sym(s)?).map_or_else(|| err("bad comparator"), Ok)
}

fn parse_keyword(s: &Sexpr) -> R<Keyword> {
    Keyword::from_name(sym(s)?).map_or_else(|| err("bad keyword"), Ok)
}

fn parse_kwspec(s: &Sexpr) -> R<KwSpec> {
    match s {
        Sexpr::Sym(name) => match Keyword::from_name(name) {
            Some(Keyword::Plating) | None => err("bad keyword"),
            Some(kw) => Ok(KwSpec { kw, value: 0 }),
        },
        Sexpr::List(_) => {
            let (h, args) = form(s)?;
            if h != "plating" {
                return err("bad keyword spec");
            }
            arity(args, 1)?;
            Ok(KwSpec {
                kw: Keyword::Plating,
                value: int(&args[0])?,
            })
        }
        _ => err("bad keyword spec"),
    }
}

fn parse_filters(args: &[Sexpr]) -> R<Vec<Filter>> {
    args.iter().map(parse_filter).collect()
}

fn parse_filter(s: &Sexpr) -> R<Filter> {
    let (h, a) = form(s)?;
    let f = match h {
        "kw" => {
            arity(a, 1)?;
            Filter::Kw(parse_keyword(&a[0])?)
        }
        "no-kw" => {
            arity(a, 1)?;
            Filter::NoKw(parse_keyword(&a[0])?)
        }
        "tag" => {
            arity(a, 1)?;
            Filter::Tag(sym(&a[0])?.to_string())
        }
        "type" => {
            arity(a, 1)?;
            Filter::Type(CardType::from_name(sym(&a[0])?).map_or_else(|| err("bad type"), Ok)?)
        }
        "cost" | "edge" | "core" => {
            arity(a, 2)?;
            let c = parse_cmp(&a[0])?;
            let n = int(&a[1])?;
            match h {
                "cost" => Filter::Cost(c, n),
                "edge" => Filter::Edge(c, n),
                _ => Filter::Core(c, n),
            }
        }
        "wounded" | "ready" | "exhausted" | "settling" | "attacking" | "blocking" | "mine"
        | "enemy" | "other" => {
            arity(a, 0)?;
            match h {
                "wounded" => Filter::Wounded,
                "ready" => Filter::Ready,
                "exhausted" => Filter::Exhausted,
                "settling" => Filter::Settling,
                "attacking" => Filter::Attacking,
                "blocking" => Filter::Blocking,
                "mine" => Filter::Mine,
                "enemy" => Filter::Enemy,
                _ => Filter::Other,
            }
        }
        "not" => {
            arity(a, 1)?;
            Filter::Not(Box::new(parse_filter(&a[0])?))
        }
        _ => return err(format!("bad filter {h}")),
    };
    Ok(f)
}

fn parse_target_index(a: &[Sexpr]) -> R<usize> {
    arity(a, 1)?;
    let n = int(&a[0])?;
    if n < 1 {
        return err("target index must be positive");
    }
    Ok(n as usize)
}

fn parse_sel(s: &Sexpr) -> R<Sel> {
    if let Sexpr::Sym(name) = s {
        return match name.as_str() {
            "self" => Ok(Sel::SelfObj),
            "it" => Ok(Sel::It),
            "that" => Ok(Sel::That),
            _ => err(format!("bad selector {name}")),
        };
    }
    let (h, a) = form(s)?;
    match h {
        "t" => Ok(Sel::Target(parse_target_index(a)?)),
        "units" | "relics" | "random-unit" => {
            if a.is_empty() {
                return err("missing scope");
            }
            let scope = parse_scope(&a[0])?;
            let filters = parse_filters(&a[1..])?;
            Ok(match h {
                "units" => Sel::Units(scope, filters),
                "relics" => Sel::Relics(scope, filters),
                _ => Sel::RandomUnit(scope, filters),
            })
        }
        "cards" => {
            if a.len() < 2 {
                return err("cards needs a zone and a scope");
            }
            let zone = match sym(&a[0])? {
                "hand" => ZoneName::Hand,
                "ash" => ZoneName::Ash,
                "vault" => ZoneName::Vault,
                "rift" => ZoneName::Rift,
                _ => return err("bad zone"),
            };
            Ok(Sel::Cards(zone, parse_scope(&a[1])?, parse_filters(&a[2..])?))
        }
        _ => err(format!("bad selector {h}")),
    }
}

fn parse_psel(s: &Sexpr) -> R<PSel> {
    if let Sexpr::Sym(name) = s {
        return match name.as_str() {
            "you" => Ok(PSel::You),
            "foe" => Ok(PSel::Foe),
            "both" => Ok(PSel::Both),
            _ => err(format!("bad player selector {name}")),
        };
    }
    let (h, a) = form(s)?;
    match h {
        "t" => Ok(PSel::Target(parse_target_index(a)?)),
        "owner-of" => {
            arity(a, 1)?;
            Ok(PSel::OwnerOf(Box::new(parse_sel(&a[0])?)))
        }
        _ => err(format!("bad player selector {h}")),
    }
}

fn parse_dsel(s: &Sexpr) -> R<DSel> {
    if let Sexpr::Sym(name) = s {
        if matches!(name.as_str(), "you" | "foe" | "both") {
            return Ok(DSel::Player(parse_psel(s)?));
        }
        return Ok(DSel::Obj(parse_sel(s)?));
    }
    if let Ok(("owner-of", _)) = form(s) {
        return Ok(DSel::Player(parse_psel(s)?));
    }
    Ok(DSel::Obj(parse_sel(s)?))
}

fn parse_amt(s: &Sexpr) -> R<Amt> {
    if let Sexpr::Int(n) = s {
        return Ok(Amt::Int(*n));
    }
    let (h, a) = form(s)?;
    arity(a, 1)?;
    Ok(match h {
        "count" => Amt::Count(parse_sel(&a[0])?),
        "hand" => Amt::Hand(parse_psel(&a[0])?),
        "ash" => Amt::Ash(parse_psel(&a[0])?),
        "vault" => Amt::Vault(parse_psel(&a[0])?),
        "edge" => Amt::Edge(parse_sel(&a[0])?),
        "core" => Amt::Core(parse_sel(&a[0])?),
        "wounds" => Amt::Wounds(parse_sel(&a[0])?),
        _ => return err(format!("bad amount {h}")),
    })
}

fn parse_cond(s: &Sexpr) -> R<Cond> {
    let (h, a) = form(s)?;
    Ok(match h {
        "count" => {
            arity(a, 3)?;
            Cond::Count(parse_sel(&a[0])?, parse_cmp(&a[1])?, int(&a[2])?)
        }
        "spire" | "hand" | "ash" | "vault" | "ember" => {
            arity(a, 3)?;
            let p = parse_psel(&a[0])?;
            let c = parse_cmp(&a[1])?;
            let n = int(&a[2])?;
            match h {
                "spire" => Cond::Spire(p, c, n),
                "hand" => Cond::Hand(p, c, n),
                "ash" => Cond::Ash(p, c, n),
                "vault" => Cond::Vault(p, c, n),
                _ => Cond::Ember(p, c, n),
            }
        }
        "myturn" => {
            arity(a, 0)?;
            Cond::MyTurn
        }
        "and" => Cond::And(a.iter().map(parse_cond).collect::<R<_>>()?),
        "or" => Cond::Or(a.iter().map(parse_cond).collect::<R<_>>()?),
        "not" => {
            arity(a, 1)?;
            Cond::Not(Box::new(parse_cond(&a[0])?))
        }
        _ => return err(format!("bad condition {h}")),
    })
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

fn parse_effects(items: &[Sexpr]) -> R<Vec<Effect>> {
    items.iter().map(parse_effect).collect()
}

fn parse_effect_list(s: &Sexpr) -> R<Vec<Effect>> {
    match s {
        Sexpr::List(items) => parse_effects(items),
        _ => err("expected an effect list"),
    }
}

fn parse_card_ref(s: &Sexpr) -> R<String> {
    let id = sym(s)?;
    if is_card_id(id) {
        Ok(id.to_string())
    } else {
        err("bad card id")
    }
}

fn parse_effect(s: &Sexpr) -> R<Effect> {
    let (h, a) = form(s)?;
    let e = match h {
        "damage" => {
            arity(a, 2)?;
            Effect::Damage(parse_amt(&a[0])?, parse_dsel(&a[1])?)
        }
        "destroy" | "sacrifice" | "exile" | "bounce" | "swapstats" | "strip" | "control"
        | "ready" | "exhaust" | "doom" | "reanimate" | "recall" => {
            arity(a, 1)?;
            let sel = parse_sel(&a[0])?;
            match h {
                "destroy" => Effect::Destroy(sel),
                "sacrifice" => Effect::Sacrifice(sel),
                "exile" => Effect::Exile(sel),
                "bounce" => Effect::Bounce(sel),
                "swapstats" => Effect::Swapstats(sel),
                "strip" => Effect::Strip(sel),
                "control" => Effect::Control(sel),
                "ready" => Effect::Ready(sel),
                "exhaust" => Effect::Exhaust(sel),
                "doom" => Effect::Doom(sel),
                "reanimate" => Effect::Reanimate(sel),
                _ => Effect::Recall(sel),
            }
        }
        "draw" | "discard" | "mill" | "spire" | "ember" | "cap" | "shield" => {
            arity(a, 2)?;
            let amt = parse_amt(&a[0])?;
            let p = parse_psel(&a[1])?;
            match h {
                "draw" => Effect::Draw(amt, p),
                "discard" => Effect::Discard(amt, p),
                "mill" => Effect::Mill(amt, p),
                "spire" => Effect::Spire(amt, p),
                "ember" => Effect::Ember(amt, p),
                "cap" => Effect::Cap(amt, p),
                _ => Effect::Shield(amt, p),
            }
        }
        "modify" | "setbody" => {
            arity(a, 3)?;
            let x = parse_amt(&a[0])?;
            let y = parse_amt(&a[1])?;
            let sel = parse_sel(&a[2])?;
            if h == "modify" {
                Effect::Modify(x, y, sel)
            } else {
                Effect::Setbody(x, y, sel)
            }
        }
        "grant" => {
            arity(a, 2)?;
            Effect::Grant(parse_kwspec(&a[0])?, parse_sel(&a[1])?)
        }
        "counters" | "ward" => {
            arity(a, 2)?;
            let amt = parse_amt(&a[0])?;
            let sel = parse_sel(&a[1])?;
            if h == "counters" {
                Effect::Counters(amt, sel)
            } else {
                Effect::Ward(amt, sel)
            }
        }
        "summon" | "conjure" => {
            arity(a, 3)?;
            let id = parse_card_ref(&a[0])?;
            let amt = parse_amt(&a[1])?;
            let p = parse_psel(&a[2])?;
            if h == "summon" {
                Effect::Summon(id, amt, p)
            } else {
                Effect::Conjure(id, amt, p)
            }
        }
        "negate" => {
            arity(a, 1)?;
            match parse_sel(&a[0])? {
                Sel::Target(n) => Effect::Negate(n),
                _ => return err("negate needs a target"),
            }
        }
        "dig" => {
            arity(a, 3)?;
            let k = int(&a[0])?;
            let filters = match &a[1] {
                Sexpr::List(items) => parse_filters(items)?,
                _ => return err("dig needs a filter list"),
            };
            Effect::Dig(k, filters, parse_psel(&a[2])?)
        }
        "delay" => {
            if a.is_empty() {
                return err("delay needs a time");
            }
            let when = When::from_name(sym(&a[0])?).map_or_else(|| err("bad delay time"), Ok)?;
            Effect::Delay(when, Rc::new(parse_effects(&a[1..])?))
        }
        "if" => {
            if a.len() != 2 && a.len() != 3 {
                return err("bad if");
            }
            let cond = parse_cond(&a[0])?;
            let then = parse_effect_list(&a[1])?;
            let otherwise = if a.len() == 3 {
                parse_effect_list(&a[2])?
            } else {
                Vec::new()
            };
            Effect::If(cond, then, otherwise)
        }
        "each" => {
            if a.is_empty() {
                return err("each needs a selector");
            }
            Effect::Each(parse_sel(&a[0])?, parse_effects(&a[1..])?)
        }
        "repeat" => {
            if a.is_empty() {
                return err("repeat needs an amount");
            }
            Effect::Repeat(parse_amt(&a[0])?, parse_effects(&a[1..])?)
        }
        "nothing" => {
            arity(a, 0)?;
            Effect::Nothing
        }
        _ => return err(format!("unknown effect {h}")),
    };
    Ok(e)
}

// ---------------------------------------------------------------------------
// Statics, costs, target specs
// ---------------------------------------------------------------------------

fn parse_static(s: &Sexpr) -> R<Static> {
    let (h, a) = form(s)?;
    Ok(match h {
        "modify" | "setbody" => {
            arity(a, 3)?;
            let x = parse_amt(&a[0])?;
            let y = parse_amt(&a[1])?;
            let sel = parse_sel(&a[2])?;
            if h == "modify" {
                Static::Modify(x, y, sel)
            } else {
                Static::Setbody(x, y, sel)
            }
        }
        "swapstats" => {
            arity(a, 1)?;
            Static::Swapstats(parse_sel(&a[0])?)
        }
        "grant" => {
            arity(a, 2)?;
            Static::Grant(parse_kwspec(&a[0])?, parse_sel(&a[1])?)
        }
        "cheaper" => {
            if a.is_empty() {
                return err("cheaper needs an amount");
            }
            let n = int(&a[0])?;
            let mut filters = Vec::new();
            for f in &a[1..] {
                let (fh, fa) = form(f)?;
                filters.push(match fh {
                    "type" => {
                        arity(fa, 1)?;
                        CardFilter::Type(
                            CardType::from_name(sym(&fa[0])?).map_or_else(|| err("bad type"), Ok)?,
                        )
                    }
                    "tag" => {
                        arity(fa, 1)?;
                        CardFilter::Tag(sym(&fa[0])?.to_string())
                    }
                    "cost" => {
                        arity(fa, 2)?;
                        CardFilter::Cost(parse_cmp(&fa[0])?, int(&fa[1])?)
                    }
                    _ => return err("bad card filter"),
                });
            }
            Static::Cheaper(n, filters)
        }
        "when" => {
            if a.is_empty() {
                return err("when needs a condition");
            }
            let cond = parse_cond(&a[0])?;
            let inner = a[1..].iter().map(parse_static).collect::<R<Vec<_>>>()?;
            Static::When(cond, inner)
        }
        _ => return err(format!("bad static {h}")),
    })
}

fn parse_cost_items(items: &[Sexpr]) -> R<Vec<CostItem>> {
    let mut out = Vec::new();
    for it in items {
        let (h, a) = form(it)?;
        out.push(match h {
            "ember" | "spire" | "discard" | "counters" => {
                arity(a, 1)?;
                let n = int(&a[0])?;
                match h {
                    "ember" => CostItem::Ember(n),
                    "spire" => CostItem::Spire(n),
                    "discard" => CostItem::Discard(n),
                    _ => CostItem::Counters(n),
                }
            }
            "exhaust" => {
                arity(a, 0)?;
                CostItem::Exhaust
            }
            "sacself" => {
                arity(a, 0)?;
                CostItem::SacSelf
            }
            "once" => {
                arity(a, 0)?;
                CostItem::Once
            }
            _ => return err(format!("bad cost item {h}")),
        });
    }
    Ok(out)
}

fn parse_tspecs(items: &[Sexpr]) -> R<Vec<TSpec>> {
    let mut out = Vec::new();
    for it in items {
        let (h, a) = form(it)?;
        out.push(match h {
            "unit" => TSpec::Unit(parse_filters(a)?),
            "relic" => TSpec::Relic(parse_filters(a)?),
            "any" => TSpec::Any(parse_filters(a)?),
            "ashcard" => TSpec::AshCard(parse_filters(a)?),
            "player" => {
                arity(a, 0)?;
                TSpec::Player
            }
            "chained" => {
                arity(a, 0)?;
                TSpec::Chained
            }
            _ => return err(format!("bad target spec {h}")),
        });
    }
    Ok(out)
}

fn join(items: &[Sexpr]) -> String {
    items
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>()
        .join(" ")
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

/// The parts of an `on`/`act`/`resolve` clause body.
struct AbilityParts {
    cost: Vec<CostItem>,
    cost_text: String,
    targets: Vec<TSpec>,
    targets_text: String,
    effects: Vec<Effect>,
    effects_text: String,
}

fn parse_ability_parts(parts: &[Sexpr], allow_cost: bool) -> R<AbilityParts> {
    let mut cost = None;
    let mut targets = None;
    let mut effect_items: Vec<&Sexpr> = Vec::new();
    for p in parts {
        let (h, a) = form(p)?;
        match h {
            "cost" => {
                if !allow_cost || cost.is_some() || !effect_items.is_empty() {
                    return err("misplaced cost");
                }
                cost = Some((parse_cost_items(a)?, p.to_string()));
            }
            "targets" => {
                if targets.is_some() || !effect_items.is_empty() {
                    return err("misplaced targets");
                }
                targets = Some((parse_tspecs(a)?, p.to_string()));
            }
            _ => effect_items.push(p),
        }
    }
    if effect_items.is_empty() {
        return err("ability has no effects");
    }
    if allow_cost && cost.is_none() {
        return err("act without a cost");
    }
    let effects = effect_items
        .iter()
        .map(|s| parse_effect(s))
        .collect::<R<Vec<_>>>()?;
    let effects_text = effect_items
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>()
        .join(" ");
    let (cost, cost_text) = cost.unwrap_or((Vec::new(), String::new()));
    let (targets, targets_text) = targets.unwrap_or((Vec::new(), "-".to_string()));
    Ok(AbilityParts {
        cost,
        cost_text,
        targets,
        targets_text,
        effects,
        effects_text,
    })
}

fn parse_card(form_s: &Sexpr) -> R<Card> {
    let (h, args) = form(form_s)?;
    if h != "card" {
        return err("top-level form is not a card");
    }
    let id = match args.first() {
        Some(Sexpr::Sym(s)) if is_card_id(s) => s.clone(),
        _ => return err("bad card id"),
    };
    let clauses = &args[1..];

    let mut name = None;
    let mut ctype = None;
    let mut cost = None;
    let mut body = None;
    let mut tags = None;
    let mut keywords = None;
    let mut text = None;
    let mut resolve: Option<AbilityParts> = None;
    // (kind, event, parts-or-statics)
    enum Later {
        On(Event, AbilityParts),
        Act(AbilityParts),
        Aura(Vec<Static>, String),
    }
    let mut later: Vec<Later> = Vec::new();

    for c in clauses {
        let (ch, ca) = form(c)?;
        match ch {
            "name" => {
                arity(ca, 1)?;
                let Sexpr::Str(s) = &ca[0] else {
                    return err("name must be a string");
                };
                if name.replace(s.clone()).is_some() {
                    return err("duplicate name");
                }
            }
            "type" => {
                arity(ca, 1)?;
                let t = CardType::from_name(sym(&ca[0])?).map_or_else(|| err("bad type"), Ok)?;
                if ctype.replace(t).is_some() {
                    return err("duplicate type");
                }
            }
            "cost" => {
                arity(ca, 1)?;
                let n = int(&ca[0])?;
                if n < 0 || cost.replace(n).is_some() {
                    return err("bad or duplicate cost");
                }
            }
            "body" => {
                arity(ca, 2)?;
                let e = int(&ca[0])?;
                let k = int(&ca[1])?;
                if e < 0 || k < 0 || body.replace((e, k)).is_some() {
                    return err("bad or duplicate body");
                }
            }
            "tags" => {
                let list = ca
                    .iter()
                    .map(|s| sym(s).map(str::to_string))
                    .collect::<R<Vec<_>>>()?;
                if tags.replace(list).is_some() {
                    return err("duplicate tags");
                }
            }
            "keywords" => {
                let list = ca.iter().map(parse_kwspec_decl).collect::<R<Vec<_>>>()?;
                if keywords.replace(list).is_some() {
                    return err("duplicate keywords");
                }
            }
            "text" => {
                arity(ca, 1)?;
                let Sexpr::Str(s) = &ca[0] else {
                    return err("text must be a string");
                };
                if text.replace(s.clone()).is_some() {
                    return err("duplicate text");
                }
            }
            "resolve" => {
                if resolve.is_some() {
                    return err("duplicate resolve");
                }
                resolve = Some(parse_ability_parts(ca, false)?);
            }
            "on" => {
                let Some(ev) = ca.first().and_then(|e| e.as_sym()).and_then(Event::from_name)
                else {
                    return err("bad event");
                };
                later.push(Later::On(ev, parse_ability_parts(&ca[1..], false)?));
            }
            "act" => later.push(Later::Act(parse_ability_parts(ca, true)?)),
            "aura" => {
                if ca.is_empty() {
                    return err("empty aura");
                }
                let statics = ca.iter().map(parse_static).collect::<R<Vec<_>>>()?;
                later.push(Later::Aura(statics, join(ca)));
            }
            _ => return err(format!("unknown clause {ch}")),
        }
    }

    let name = name.map_or_else(|| err("missing name"), Ok)?;
    let ctype = ctype.map_or_else(|| err("missing type"), Ok)?;
    let cost = cost.map_or_else(|| err("missing cost"), Ok)?;
    let (edge, core) = match (ctype, body) {
        (CardType::Unit, Some(b)) => b,
        (CardType::Unit, None) => return err("unit without body"),
        (_, Some(_)) => return err("body on a non-unit"),
        (_, None) => (0, 0),
    };
    match (ctype, &resolve) {
        (CardType::Rite, None) => return err("rite without resolve"),
        (CardType::Rite, Some(_)) => {}
        (_, Some(_)) => return err("resolve on a non-rite"),
        _ => {}
    }
    let keywords = keywords.unwrap_or_default();
    for k in &keywords {
        if !k.kw.legal_on(ctype) {
            return err(format!("keyword {} not allowed on a {}", k.kw.name(), ctype.name()));
        }
    }

    let empty_targets = Rc::new(Vec::new());
    let empty_effects = Rc::new(Vec::new());
    let mut abilities = Vec::new();
    let mut event_mask = 0u32;
    if let Some(r) = resolve {
        abilities.push(Ability {
            kind: AbilityKind::Resolve,
            event: None,
            cost: Vec::new(),
            rendered: format!("resolve {} {}", r.targets_text, r.effects_text),
            targets: Rc::new(r.targets),
            effects: Rc::new(r.effects),
            statics: Vec::new(),
        });
    }
    let mut ons = Vec::new();
    let mut acts = Vec::new();
    let mut auras = Vec::new();
    for l in later {
        match l {
            Later::On(ev, p) => ons.push((ev, p)),
            Later::Act(p) => acts.push(p),
            Later::Aura(s, t) => auras.push((s, t)),
        }
    }
    for (ev, p) in ons {
        event_mask |= 1u32 << ev as u32;
        abilities.push(Ability {
            kind: AbilityKind::On,
            event: Some(ev),
            cost: Vec::new(),
            rendered: format!("on {} {} {}", ev.name(), p.targets_text, p.effects_text),
            targets: Rc::new(p.targets),
            effects: Rc::new(p.effects),
            statics: Vec::new(),
        });
    }
    for p in acts {
        abilities.push(Ability {
            kind: AbilityKind::Act,
            event: None,
            rendered: format!("act {} {} {}", p.cost_text, p.targets_text, p.effects_text),
            cost: p.cost,
            targets: Rc::new(p.targets),
            effects: Rc::new(p.effects),
            statics: Vec::new(),
        });
    }
    for (statics, text) in auras {
        abilities.push(Ability {
            kind: AbilityKind::Aura,
            event: None,
            cost: Vec::new(),
            targets: empty_targets.clone(),
            effects: empty_effects.clone(),
            statics,
            rendered: format!("aura {text}"),
        });
    }

    Ok(Card {
        id,
        name,
        ctype,
        cost,
        edge,
        core,
        tags: tags.unwrap_or_default(),
        keywords,
        text,
        abilities,
        event_mask,
    })
}

/// A printed keyword: like [`parse_kwspec`], used for the `keywords` clause.
fn parse_kwspec_decl(s: &Sexpr) -> R<KwSpec> {
    parse_kwspec(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(text: &str) -> Database {
        Database::parse(text).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn parses_a_small_database() {
        let db = ok(
            "(card AAA-001 (name \"One\") (type unit) (cost 1) (body 2 3) (tags x y)
               (keywords vanguard (plating 2))
               (on arrive (targets (unit (enemy))) (damage 1 (t 1)))
               (act (cost (exhaust) (ember 1)) (draw 1 you))
               (aura (when (myturn) (modify 1 1 (units yours)))))",
        );
        let c = db.get("AAA-001").unwrap();
        assert_eq!(c.abilities.len(), 3);
        assert_eq!(
            c.abilities[0].rendered,
            "on arrive (targets (unit (enemy))) (damage 1 (t 1))"
        );
        assert_eq!(
            c.abilities[1].rendered,
            "act (cost (exhaust) (ember 1)) - (draw 1 you)"
        );
        assert!(c.listens(Event::Arrive));
        assert!(!c.listens(Event::Dies));
    }

    #[test]
    fn rejects_invalid_cards() {
        let bad = [
            "(card AAA-001 (name \"x\") (type rite) (cost 1))",
            "(card AAA-001 (name \"x\") (type unit) (cost 1))",
            "(card AAA-001 (name \"x\") (type unit) (cost 1) (body 1 1) (keywords swift))",
            "(card AAA-001 (name \"x\") (type rite) (cost 1) (resolve (summon AAA-001 1 you)))",
            "(card AAA-001 (name \"x\") (type rite) (cost 1) (resolve (draw 1 you) (targets (unit))))",
            "(card AAA-001 (name \"x\") (type rite) (cost 1) (resolve (if (myturn) (draw 1 you))))",
            "(card AAA-001 (name \"x\") (type unit) (cost 1) (body 1 1))(card AAA-001 (name \"y\") (type unit) (cost 1) (body 1 1))",
            "stray",
        ];
        for text in bad {
            assert!(Database::parse(text).is_err(), "accepted: {text}");
        }
    }

    #[test]
    fn empty_database_is_valid() {
        assert!(ok("").is_empty());
        assert!(ok("; nothing here\n").is_empty());
    }

    #[test]
    fn summon_may_forward_reference_a_unit() {
        ok("(card AAA-001 (name \"a\") (type rite) (cost 1) (resolve (summon AAA-002 1 you)))
            (card AAA-002 (name \"b\") (type unit) (cost 0) (body 1 1))");
    }
}
