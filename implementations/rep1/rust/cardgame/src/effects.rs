//! The effect interpreter (SPEC.md 6.8–6.9).

use std::rc::Rc;

use crate::eval::Ctx;
use crate::model::*;
use crate::state::*;

impl Engine {
    /// Execute effects in written order.
    pub(crate) fn exec_effects(&mut self, effects: &[Effect], ctx: &mut Ctx) {
        for e in effects {
            self.exec(e, ctx);
        }
    }

    fn exec(&mut self, e: &Effect, ctx: &mut Ctx) {
        match e {
            Effect::Damage(amt, dsel) => {
                let n = self.eval_amt(amt, ctx);
                if n <= 0 {
                    return;
                }
                let targets = self.eval_dsel(dsel, ctx);
                for t in targets {
                    self.deal_damage(ctx.src, t, n);
                }
            }
            Effect::Destroy(sel) => {
                for o in self.eval_sel(sel, ctx) {
                    self.destroy(o);
                }
            }
            Effect::Sacrifice(sel) => {
                for o in self.eval_sel(sel, ctx) {
                    self.sacrifice(o);
                }
            }
            Effect::Exile(sel) => {
                for o in self.eval_sel(sel, ctx) {
                    self.exile(o);
                }
            }
            Effect::Bounce(sel) => {
                for o in self.eval_sel(sel, ctx) {
                    self.bounce(o);
                }
            }
            Effect::Draw(amt, psel) => {
                let n = self.eval_amt(amt, ctx);
                if n <= 0 {
                    return;
                }
                for p in self.eval_psel(psel, ctx) {
                    for _ in 0..n {
                        if !self.draw_one(p) {
                            break;
                        }
                    }
                }
            }
            Effect::Discard(amt, psel) => {
                let n = self.eval_amt(amt, ctx);
                if n <= 0 {
                    return;
                }
                for p in self.eval_psel(psel, ctx) {
                    for _ in 0..n {
                        self.discard_one(p);
                    }
                }
            }
            Effect::Mill(amt, psel) => {
                let n = self.eval_amt(amt, ctx);
                if n <= 0 {
                    return;
                }
                for p in self.eval_psel(psel, ctx) {
                    for _ in 0..n {
                        self.mill_one(p);
                    }
                }
            }
            Effect::Spire(amt, psel) => {
                let n = self.eval_amt(amt, ctx);
                for p in self.eval_psel(psel, ctx) {
                    self.change_spire(p, n);
                }
            }
            Effect::Ember(amt, psel) => {
                let n = self.eval_amt(amt, ctx);
                if n <= 0 {
                    return;
                }
                for p in self.eval_psel(psel, ctx) {
                    self.gain_ember(p, n);
                }
            }
            Effect::Cap(amt, psel) => {
                let n = self.eval_amt(amt, ctx);
                if n <= 0 {
                    return;
                }
                for p in self.eval_psel(psel, ctx) {
                    self.raise_cap(p, n);
                }
            }
            Effect::Modify(a, b, sel) => {
                let x = self.eval_amt(a, ctx);
                let y = self.eval_amt(b, ctx);
                self.create_record(RecKind::Modify(x, y), sel, ctx);
            }
            Effect::Setbody(a, b, sel) => {
                let x = self.eval_amt(a, ctx);
                let y = self.eval_amt(b, ctx);
                self.create_record(RecKind::Setbody(x, y), sel, ctx);
            }
            Effect::Swapstats(sel) => self.create_record(RecKind::Swap, sel, ctx),
            Effect::Grant(k, sel) => self.create_record(RecKind::Grant(*k), sel, ctx),
            Effect::Strip(sel) => self.create_record(RecKind::Strip, sel, ctx),
            Effect::Control(sel) => self.create_record(RecKind::Control, sel, ctx),
            Effect::Counters(amt, sel) => {
                let n = self.eval_amt(amt, ctx);
                for o in self.eval_sel(sel, ctx) {
                    self.add_counters(o, n);
                }
            }
            Effect::Ready(sel) => {
                for o in self.eval_sel(sel, ctx) {
                    self.set_exhausted(o, false);
                }
            }
            Effect::Exhaust(sel) => {
                for o in self.eval_sel(sel, ctx) {
                    self.set_exhausted(o, true);
                }
            }
            Effect::Doom(sel) => {
                for o in self.eval_sel(sel, ctx) {
                    self.doom(o);
                }
            }
            Effect::Ward(amt, sel) => {
                let n = self.eval_amt(amt, ctx);
                if n <= 0 {
                    return;
                }
                for o in self.eval_sel(sel, ctx) {
                    if self.on_field(o) {
                        let ob = self.obj_mut(o);
                        ob.fs.ward += n;
                        let pool = ob.fs.ward;
                        self.touch();
                        self.emit(format!("WARD #{o} {n} {pool}"));
                    }
                }
            }
            Effect::Shield(amt, psel) => {
                let n = self.eval_amt(amt, ctx);
                if n <= 0 {
                    return;
                }
                for p in self.eval_psel(psel, ctx) {
                    let ps = &mut self.players[p.idx()];
                    ps.shield += n;
                    let pool = ps.shield;
                    self.emit(format!("SHIELD {} {} {}", p.name(), n, pool));
                }
            }
            Effect::Summon(id, amt, psel) => self.create_cards(id, amt, psel, ctx, true),
            Effect::Conjure(id, amt, psel) => self.create_cards(id, amt, psel, ctx, false),
            Effect::Reanimate(sel) => {
                for o in self.eval_sel(sel, ctx) {
                    let ob = self.obj(o);
                    if ob.zone == Zone::Ash && ob.is_unit() {
                        self.detach_from_zone(o);
                        self.enter_field(o, ctx.ctrl, false);
                    }
                }
            }
            Effect::Recall(sel) => {
                for o in self.eval_sel(sel, ctx) {
                    if self.obj(o).zone == Zone::Ash {
                        self.detach_from_zone(o);
                        self.push_hand(o);
                        let id = self.obj(o).card.id.clone();
                        self.emit(format!("RECALL #{o} {id}"));
                    }
                }
            }
            Effect::Negate(n) => {
                if let Some(TSlot { tgt: Tgt::Entry(c), removed: false }) = ctx.targets.get(n - 1) {
                    let c = *c;
                    self.negate_entry(c);
                }
            }
            Effect::Dig(k, filters, psel) => {
                for p in self.eval_psel(psel, ctx) {
                    self.dig(p, *k, filters, ctx.ctrl, ctx.src);
                }
            }
            Effect::Delay(when, effects) => {
                let ts = self.new_ts();
                let d = Delayed {
                    ts,
                    ctrl: ctx.ctrl,
                    src: ctx.src,
                    when: *when,
                    targets: ctx.targets.iter().map(|s| s.tgt).collect(),
                    specs: ctx.specs.clone(),
                    effects: effects.clone(),
                };
                self.delayed.push(Rc::new(d));
                self.emit(format!("DELAY {} {}", ctx.ctrl.name(), when.name()));
            }
            Effect::If(cond, then, otherwise) => {
                if self.eval_cond(cond, ctx) {
                    self.exec_effects(then, ctx);
                } else {
                    self.exec_effects(otherwise, ctx);
                }
            }
            Effect::Each(sel, body) => {
                let list = self.eval_sel(sel, ctx);
                let zones: Vec<(Oid, Zone)> =
                    list.into_iter().map(|o| (o, self.obj(o).zone)).collect();
                for (o, z) in zones {
                    if self.obj(o).zone != z {
                        continue;
                    }
                    ctx.that.push(o);
                    self.exec_effects(body, ctx);
                    ctx.that.pop();
                }
            }
            Effect::Repeat(amt, body) => {
                let n = self.eval_amt(amt, ctx);
                for _ in 0..n.max(0) {
                    self.exec_effects(body, ctx);
                }
            }
            Effect::Nothing => {}
        }
    }

    /// Create `n` objects of `card` for each selected player; summoned ones
    /// enter the Field, conjured ones go to the hand (SPEC.md 17.17).
    fn create_cards(&mut self, id: &str, amt: &Amt, psel: &PSel, ctx: &Ctx, field: bool) {
        let n = self.eval_amt(amt, ctx);
        if n <= 0 {
            return;
        }
        let card = self.db.get(id).expect("validated at load").clone();
        for p in self.eval_psel(psel, ctx) {
            for _ in 0..n {
                let o = self.new_object(card.clone(), p);
                self.emit(format!("CREATE #{} {} {}", o, id, if field { "field" } else { "hand" }));
                if field {
                    self.enter_field(o, p, false);
                } else {
                    self.push_hand(o);
                }
            }
        }
    }

    /// Create a discrete continuous-effect record (SPEC.md 14.1) and emit the
    /// per-object event.
    fn create_record(&mut self, kind: RecKind, sel: &Sel, ctx: &Ctx) {
        let mut affected = self.eval_sel(sel, ctx);
        affected.retain(|&o| self.on_field(o));
        self.sort_canonical(&mut affected);
        let eid = self.next_eid;
        self.next_eid += 1;
        let ts = self.new_ts();
        self.records.push(Record {
            eid,
            ts,
            ctrl: ctx.ctrl,
            src: ctx.src,
            kind: kind.clone(),
            affected: affected.clone(),
        });
        self.touch();
        let turn = self.turn;
        for o in affected {
            match &kind {
                RecKind::Modify(e, c) => self.emit(format!("BUFF #{o} {e} {c}")),
                RecKind::Setbody(e, c) => self.emit(format!("SETBODY #{o} {e} {c}")),
                RecKind::Swap => self.emit(format!("SWAP #{o}")),
                RecKind::Grant(k) => self.emit(format!("GRANT #{o} {}", k.render())),
                RecKind::Strip => self.emit(format!("STRIP #{o}")),
                RecKind::Control => {
                    self.obj_mut(o).fs.since = turn;
                    self.remove_from_combat(o);
                    self.touch();
                    self.emit(format!("CONTROL #{o} {}", ctx.ctrl.name()));
                }
                RecKind::Aura { .. } => {}
            }
        }
    }
}
