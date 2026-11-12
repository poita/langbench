//! Whole-board derivation of current characteristics (SPEC.md section 14).
//!
//! One pass walks the continuous-effect records in `(timestamp, eid)` order,
//! layer by layer, and writes the result into each Field object's
//! [`Current`]. Auras are evaluated once per pass.

use crate::eval::Ctx;
use crate::model::*;
use crate::state::*;

enum Eff {
    Modify(i64, i64),
    Setbody(i64, i64),
    Swap,
    Grant(KwSpec),
    Strip,
    Skip,
}

fn apply(objs: &mut [Obj], layer: u8, eff: &Eff, affected: &[Oid]) {
    for &o in affected {
        let ob = &mut objs[o as usize - 1];
        if ob.zone != Zone::Field {
            continue;
        }
        let c = &mut ob.cur;
        match (layer, eff) {
            (2, Eff::Grant(k)) => c.kw.add(*k),
            (2, Eff::Strip) => c.kw.clear(),
            (3, Eff::Setbody(e, k)) => {
                c.edge = *e;
                c.core = *k;
            }
            (4, Eff::Modify(e, k)) => {
                c.edge += *e;
                c.core += *k;
            }
            (6, Eff::Swap) => std::mem::swap(&mut c.edge, &mut c.core),
            _ => {}
        }
    }
}

impl Engine {
    /// Recompute every Field object's current characteristics and every aura
    /// record's evaluation.
    pub(crate) fn derive(&mut self) {
        self.dirty = false;
        self.in_derive = true;
        self.aura_evals.clear();

        // Reset to printed values.
        for i in 0..self.field.len() {
            let o = self.field[i];
            let ob = &mut self.objs[o as usize - 1];
            ob.cur = Current {
                ctrl: ob.base_ctrl,
                edge: ob.card.edge,
                core: ob.card.core,
                kw: KwSet::from_specs(&ob.card.keywords),
                stripped: false,
            };
        }

        // Step 1 and 2: layer-1 controllers, stripped objects.
        for ri in 0..self.records.len() {
            let r = &self.records[ri];
            match r.kind {
                RecKind::Control => {
                    for &o in &r.affected {
                        let ob = &mut self.objs[o as usize - 1];
                        if ob.zone == Zone::Field {
                            ob.cur.ctrl = r.ctrl;
                        }
                    }
                }
                RecKind::Strip => {
                    for &o in &r.affected {
                        let ob = &mut self.objs[o as usize - 1];
                        if ob.zone == Zone::Field {
                            ob.cur.stripped = true;
                        }
                    }
                }
                _ => {}
            }
        }

        // Step 3: evaluate auras.
        for ri in 0..self.records.len() {
            let (src, ability) = match &self.records[ri].kind {
                RecKind::Aura { ability } => (self.records[ri].src, *ability),
                _ => continue,
            };
            let (ctrl, stripped, card) = {
                let ob = &self.objs[src as usize - 1];
                (ob.cur.ctrl, ob.cur.stripped, ob.card.clone())
            };
            let ctx = Ctx::simple(ctrl, src);
            let mut leaves = Vec::new();
            for st in &card.abilities[ability].statics {
                self.eval_static(st, !stripped, &ctx, &mut leaves);
            }
            self.aura_evals.push(AuraEval { ctrl, leaves });
        }

        // Steps 4 and 5: layers.
        for layer in [2u8, 3, 4] {
            self.apply_layer(layer);
        }
        for i in 0..self.field.len() {
            let o = self.field[i];
            let ob = &mut self.objs[o as usize - 1];
            let n = ob.fs.counters;
            ob.cur.edge += n;
            ob.cur.core += n;
        }
        self.apply_layer(6);
        self.in_derive = false;
    }

    fn apply_layer(&mut self, layer: u8) {
        let mut aura_i = 0;
        for ri in 0..self.records.len() {
            let r = &self.records[ri];
            if let RecKind::Aura { .. } = r.kind {
                let ev = &self.aura_evals[aura_i];
                aura_i += 1;
                for leaf in &ev.leaves {
                    if !leaf.active {
                        continue;
                    }
                    let eff = match &leaf.kind {
                        LeafKind::Modify(e, c) => Eff::Modify(*e, *c),
                        LeafKind::Setbody(e, c) => Eff::Setbody(*e, *c),
                        LeafKind::Swap => Eff::Swap,
                        LeafKind::Grant(k) => Eff::Grant(*k),
                        LeafKind::Cheaper(..) => Eff::Skip,
                    };
                    apply(&mut self.objs, layer, &eff, &leaf.affected);
                }
            } else {
                let eff = match &r.kind {
                    RecKind::Modify(e, c) => Eff::Modify(*e, *c),
                    RecKind::Setbody(e, c) => Eff::Setbody(*e, *c),
                    RecKind::Swap => Eff::Swap,
                    RecKind::Grant(k) => Eff::Grant(*k),
                    RecKind::Strip => Eff::Strip,
                    _ => Eff::Skip,
                };
                apply(&mut self.objs, layer, &eff, &r.affected);
            }
        }
    }

    fn eval_static(&mut self, st: &Static, active: bool, ctx: &Ctx, out: &mut Vec<Leaf>) {
        match st {
            Static::Modify(a, b, sel) => {
                let x = self.eval_amt(a, ctx);
                let y = self.eval_amt(b, ctx);
                let affected = if active { self.eval_sel(sel, ctx) } else { Vec::new() };
                out.push(Leaf { kind: LeafKind::Modify(x, y), active, affected });
            }
            Static::Setbody(a, b, sel) => {
                let x = self.eval_amt(a, ctx);
                let y = self.eval_amt(b, ctx);
                let affected = if active { self.eval_sel(sel, ctx) } else { Vec::new() };
                out.push(Leaf { kind: LeafKind::Setbody(x, y), active, affected });
            }
            Static::Swapstats(sel) => {
                let affected = if active { self.eval_sel(sel, ctx) } else { Vec::new() };
                out.push(Leaf { kind: LeafKind::Swap, active, affected });
            }
            Static::Grant(k, sel) => {
                let affected = if active { self.eval_sel(sel, ctx) } else { Vec::new() };
                out.push(Leaf { kind: LeafKind::Grant(*k), active, affected });
            }
            Static::Cheaper(n, filters) => {
                out.push(Leaf {
                    kind: LeafKind::Cheaper(*n, filters.clone()),
                    active,
                    affected: Vec::new(),
                });
            }
            Static::When(cond, inner) => {
                let ok = self.eval_cond(cond, ctx);
                for s in inner {
                    self.eval_static(s, active && ok, ctx, out);
                }
            }
        }
    }

    /// The Ember reduction for `player` playing `card` (SPEC.md 11.2 step 4).
    pub(crate) fn cheaper_total(&mut self, player: Player, card: &Card) -> i64 {
        self.ensure();
        let mut total = 0;
        for ev in &self.aura_evals {
            if ev.ctrl != player {
                continue;
            }
            for leaf in &ev.leaves {
                if let (true, LeafKind::Cheaper(n, filters)) = (leaf.active, &leaf.kind) {
                    let ok = filters.iter().all(|f| match f {
                        CardFilter::Type(t) => card.ctype == *t,
                        CardFilter::Tag(t) => card.tags.iter().any(|x| x == t),
                        CardFilter::Cost(c, v) => c.test(card.cost, *v),
                    });
                    if ok {
                        total += *n;
                    }
                }
            }
        }
        total
    }
}
