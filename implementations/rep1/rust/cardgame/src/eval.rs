//! Evaluation of selectors, filters, amounts and conditions (SPEC.md 6.3–6.7).

use std::rc::Rc;

use crate::model::*;
use crate::state::*;

/// The context an ability's selectors and amounts are evaluated in.
#[derive(Debug, Clone)]
pub struct Ctx {
    /// The ability's controller.
    pub ctrl: Player,
    /// The ability's source object.
    pub src: Oid,
    /// The trigger subject `it`.
    pub subject: Subject,
    /// The ability's targets, with removal marks.
    pub targets: Vec<TSlot>,
    /// The specifications the targets were checked against.
    pub specs: Rc<Vec<TSpec>>,
    /// Stack of `each` bindings; the last is `that`.
    pub that: Vec<Oid>,
}

impl Ctx {
    /// A context with no targets and no subject.
    pub fn simple(ctrl: Player, src: Oid) -> Ctx {
        Ctx {
            ctrl,
            src,
            subject: Subject::None,
            targets: Vec::new(),
            specs: Rc::new(Vec::new()),
            that: Vec::new(),
        }
    }
}

impl Engine {
    /// Re-derive characteristics if anything changed since the last time.
    pub(crate) fn ensure(&mut self) {
        if self.dirty {
            self.derive();
        }
    }

    /// Controller for scope/`mine` purposes: current controller on the Field,
    /// owner elsewhere.
    pub(crate) fn ctrl_of(&self, o: Oid) -> Player {
        let ob = self.obj(o);
        if ob.zone == Zone::Field {
            ob.cur.ctrl
        } else {
            ob.owner
        }
    }

    /// Base edge: printed plus charge counters.
    pub(crate) fn base_edge(&self, o: Oid) -> i64 {
        let ob = self.obj(o);
        ob.card.edge + if ob.zone == Zone::Field { ob.fs.counters } else { 0 }
    }

    /// Base core: printed plus charge counters.
    pub(crate) fn base_core(&self, o: Oid) -> i64 {
        let ob = self.obj(o);
        ob.card.core + if ob.zone == Zone::Field { ob.fs.counters } else { 0 }
    }

    /// Current edge (printed off the Field).
    pub(crate) fn cur_edge(&self, o: Oid) -> i64 {
        let ob = self.obj(o);
        if ob.zone == Zone::Field {
            ob.cur.edge
        } else {
            ob.card.edge
        }
    }

    /// Current core (printed off the Field).
    pub(crate) fn cur_core(&self, o: Oid) -> i64 {
        let ob = self.obj(o);
        if ob.zone == Zone::Field {
            ob.cur.core
        } else {
            ob.card.core
        }
    }

    /// Whether the object currently has the keyword (printed off the Field).
    pub(crate) fn has_kw(&self, o: Oid, kw: Keyword) -> bool {
        let ob = self.obj(o);
        if ob.zone == Zone::Field {
            ob.cur.kw.has(kw)
        } else {
            ob.card.has_printed(kw)
        }
    }

    /// Whether the object is Settling (SPEC.md 16.1).
    pub(crate) fn is_settling(&self, o: Oid) -> bool {
        let ob = self.obj(o);
        ob.zone == Zone::Field && ob.fs.since >= self.turn
    }

    pub(crate) fn scope_ok(&self, o: Oid, scope: Scope, ctrl: Player) -> bool {
        match scope {
            Scope::All => true,
            Scope::Yours => self.ctrl_of(o) == ctrl,
            Scope::Theirs => self.ctrl_of(o) != ctrl,
        }
    }

    /// Test one filter against an object (base characteristics).
    pub(crate) fn filter_ok(&self, o: Oid, f: &Filter, ctrl: Player, src: Oid) -> bool {
        debug_assert!(!self.dirty);
        let ob = self.obj(o);
        let on_field = ob.zone == Zone::Field;
        match f {
            Filter::Kw(k) => ob.card.has_printed(*k),
            Filter::NoKw(k) => !ob.card.has_printed(*k),
            Filter::Tag(t) => ob.card.tags.iter().any(|x| x == t),
            Filter::Type(t) => ob.card.ctype == *t,
            Filter::Cost(c, n) => c.test(ob.card.cost, *n),
            Filter::Edge(c, n) => c.test(self.base_edge(o), *n),
            Filter::Core(c, n) => c.test(self.base_core(o), *n),
            Filter::Wounded => on_field && ob.fs.wounds > 0,
            Filter::Ready => on_field && !ob.fs.exhausted,
            Filter::Exhausted => on_field && ob.fs.exhausted,
            Filter::Settling => self.is_settling(o),
            Filter::Attacking => on_field && ob.fs.attacking,
            Filter::Blocking => on_field && ob.fs.blocking.is_some(),
            Filter::Mine => self.ctrl_of(o) == ctrl,
            Filter::Enemy => self.ctrl_of(o) != ctrl,
            Filter::Other => o != src,
            Filter::Not(inner) => !self.filter_ok(o, inner, ctrl, src),
        }
    }

    pub(crate) fn filters_ok(&self, o: Oid, fs: &[Filter], ctrl: Player, src: Oid) -> bool {
        fs.iter().all(|f| self.filter_ok(o, f, ctrl, src))
    }

    /// Field objects of one card type matching scope and filters, canonical order.
    pub(crate) fn field_matching(
        &self,
        ctype: CardType,
        scope: Scope,
        filters: &[Filter],
        ctx: &Ctx,
    ) -> Vec<Oid> {
        let mut v = Vec::new();
        for &o in &self.field {
            if self.obj(o).card.ctype == ctype
                && self.scope_ok(o, scope, ctx.ctrl)
                && self.filters_ok(o, filters, ctx.ctrl, ctx.src)
            {
                v.push(o);
            }
        }
        v
    }

    /// Evaluate an object selector.
    pub(crate) fn eval_sel(&mut self, sel: &Sel, ctx: &Ctx) -> Vec<Oid> {
        self.ensure();
        match sel {
            Sel::SelfObj => vec![ctx.src],
            Sel::It => match ctx.subject {
                Subject::Obj(o) => vec![o],
                _ => Vec::new(),
            },
            Sel::That => ctx.that.last().copied().into_iter().collect(),
            Sel::Target(n) => match ctx.targets.get(n - 1) {
                Some(TSlot { tgt: Tgt::Obj(o), removed: false }) => vec![*o],
                _ => Vec::new(),
            },
            Sel::Units(scope, filters) => self.field_matching(CardType::Unit, *scope, filters, ctx),
            Sel::Relics(scope, filters) => {
                self.field_matching(CardType::Relic, *scope, filters, ctx)
            }
            Sel::RandomUnit(scope, filters) => {
                let list = self.field_matching(CardType::Unit, *scope, filters, ctx);
                if list.is_empty() {
                    Vec::new()
                } else {
                    let i = self.rng.below(list.len() as u64) as usize;
                    vec![list[i]]
                }
            }
            Sel::Cards(zone, scope, filters) => {
                let mut v = Vec::new();
                for p in Player::BOTH {
                    let ps = &self.players[p.idx()];
                    let ids: Vec<Oid> = match zone {
                        ZoneName::Hand => ps.hand.clone(),
                        ZoneName::Ash => ps.ash.clone(),
                        ZoneName::Rift => ps.rift.clone(),
                        ZoneName::Vault => ps.vault.iter().copied().collect(),
                    };
                    for o in ids {
                        if self.scope_ok(o, *scope, ctx.ctrl)
                            && self.filters_ok(o, filters, ctx.ctrl, ctx.src)
                        {
                            v.push(o);
                        }
                    }
                }
                self.sort_canonical(&mut v);
                v
            }
        }
    }

    /// Evaluate a player selector.
    pub(crate) fn eval_psel(&mut self, p: &PSel, ctx: &Ctx) -> Vec<Player> {
        match p {
            PSel::You => vec![ctx.ctrl],
            PSel::Foe => vec![ctx.ctrl.other()],
            PSel::Both => vec![Player::A, Player::B],
            PSel::Target(n) => match ctx.targets.get(n - 1) {
                Some(TSlot { tgt: Tgt::Player(p), .. }) => vec![*p],
                _ => Vec::new(),
            },
            PSel::OwnerOf(sel) => {
                if let Sel::Target(n) = &**sel {
                    if let Some(TSlot { tgt: Tgt::Player(p), .. }) = ctx.targets.get(n - 1) {
                        return vec![*p];
                    }
                }
                let objs = self.eval_sel(sel, ctx);
                let mut out: Vec<Player> = Vec::new();
                for o in objs {
                    let owner = self.obj(o).owner;
                    if !out.contains(&owner) {
                        out.push(owner);
                    }
                }
                out.sort();
                out
            }
        }
    }

    /// Evaluate a damage selector into targets in ascending target-key order.
    pub(crate) fn eval_dsel(&mut self, d: &DSel, ctx: &Ctx) -> Vec<Tgt> {
        let mut out: Vec<Tgt> = match d {
            DSel::Player(p) => self.eval_psel(p, ctx).into_iter().map(Tgt::Player).collect(),
            DSel::Obj(Sel::Target(n)) => match ctx.targets.get(n - 1) {
                Some(TSlot { tgt: t @ (Tgt::Player(_) | Tgt::Obj(_)), removed: false }) => {
                    vec![*t]
                }
                _ => Vec::new(),
            },
            DSel::Obj(Sel::It) => match ctx.subject {
                Subject::Obj(o) => vec![Tgt::Obj(o)],
                Subject::Player(p) => vec![Tgt::Player(p)],
                Subject::None => Vec::new(),
            },
            DSel::Obj(sel) => self.eval_sel(sel, ctx).into_iter().map(Tgt::Obj).collect(),
        };
        out.sort_by_key(|&t| self.tgt_key(t));
        out
    }

    /// Evaluate an amount.
    pub(crate) fn eval_amt(&mut self, a: &Amt, ctx: &Ctx) -> i64 {
        self.ensure();
        match a {
            Amt::Int(n) => *n,
            Amt::Count(sel) => self.eval_sel(sel, ctx).len() as i64,
            Amt::Hand(p) => self.sum_players(p, ctx, |ps| ps.hand.len()),
            Amt::Ash(p) => self.sum_players(p, ctx, |ps| ps.ash.len()),
            Amt::Vault(p) => self.sum_players(p, ctx, |ps| ps.vault.len()),
            Amt::Edge(sel) => {
                let objs = self.eval_sel(sel, ctx);
                objs.iter()
                    .map(|&o| if self.in_derive { self.base_edge(o) } else { self.cur_edge(o) })
                    .sum()
            }
            Amt::Core(sel) => {
                let objs = self.eval_sel(sel, ctx);
                objs.iter()
                    .map(|&o| if self.in_derive { self.base_core(o) } else { self.cur_core(o) })
                    .sum()
            }
            Amt::Wounds(sel) => {
                let objs = self.eval_sel(sel, ctx);
                objs.iter()
                    .map(|&o| if self.on_field(o) { self.obj(o).fs.wounds } else { 0 })
                    .sum()
            }
        }
    }

    fn sum_players(&mut self, p: &PSel, ctx: &Ctx, f: impl Fn(&PlayerState) -> usize) -> i64 {
        let ps = self.eval_psel(p, ctx);
        ps.iter().map(|q| f(&self.players[q.idx()]) as i64).sum()
    }

    /// Evaluate a condition.
    pub(crate) fn eval_cond(&mut self, c: &Cond, ctx: &Ctx) -> bool {
        self.ensure();
        match c {
            Cond::Count(sel, cmp, n) => cmp.test(self.eval_sel(sel, ctx).len() as i64, *n),
            Cond::Spire(p, cmp, n) => {
                let v = self.sum_players_i64(p, ctx, |ps| ps.spire);
                cmp.test(v, *n)
            }
            Cond::Hand(p, cmp, n) => {
                let v = self.sum_players(p, ctx, |ps| ps.hand.len());
                cmp.test(v, *n)
            }
            Cond::Ash(p, cmp, n) => {
                let v = self.sum_players(p, ctx, |ps| ps.ash.len());
                cmp.test(v, *n)
            }
            Cond::Vault(p, cmp, n) => {
                let v = self.sum_players(p, ctx, |ps| ps.vault.len());
                cmp.test(v, *n)
            }
            Cond::Ember(p, cmp, n) => {
                let v = self.sum_players_i64(p, ctx, |ps| ps.ember);
                cmp.test(v, *n)
            }
            Cond::MyTurn => self.active == ctx.ctrl,
            Cond::And(cs) => {
                for c in cs {
                    if !self.eval_cond(c, ctx) {
                        return false;
                    }
                }
                true
            }
            Cond::Or(cs) => {
                for c in cs {
                    if self.eval_cond(c, ctx) {
                        return true;
                    }
                }
                false
            }
            Cond::Not(inner) => !self.eval_cond(inner, ctx),
        }
    }

    fn sum_players_i64(&mut self, p: &PSel, ctx: &Ctx, f: impl Fn(&PlayerState) -> i64) -> i64 {
        let ps = self.eval_psel(p, ctx);
        ps.iter().map(|q| f(&self.players[q.idx()])).sum()
    }
}
