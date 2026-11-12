//! Combat: declarations, legality and damage (SPEC.md section 19).

use crate::model::*;
use crate::state::*;

/// (source key, target key, source, target, amount) of one combat assignment.
type Triple = ((u8, u64, u64), (u8, u64, u64), Oid, Tgt, i64);

impl Engine {
    pub(crate) fn units_in_combat(&self) -> Vec<Oid> {
        self.field
            .iter()
            .copied()
            .filter(|&o| {
                let ob = self.obj(o);
                ob.is_unit() && (ob.fs.attacking || ob.fs.blocking.is_some())
            })
            .collect()
    }

    pub(crate) fn any_riposte_in_combat(&mut self) -> bool {
        self.ensure();
        self.units_in_combat().into_iter().any(|o| self.has_kw(o, Keyword::Riposte))
    }

    pub(crate) fn clear_combat(&mut self) {
        for i in 0..self.field.len() {
            let o = self.field[i];
            let fs = &mut self.obj_mut(o).fs;
            fs.attacking = false;
            fs.blocking = None;
            fs.blockers.clear();
            fs.blocked = false;
        }
        self.riposte_dealt.clear();
        self.touch();
    }

    /// SPEC.md 19.2.
    pub(crate) fn can_attack(&self, o: Oid) -> bool {
        if o < 1 || o as usize > self.objs.len() {
            return false;
        }
        let ob = self.obj(o);
        ob.zone == Zone::Field
            && ob.cur.ctrl == self.active
            && ob.is_unit()
            && !ob.fs.exhausted
            && (!self.is_settling(o) || ob.cur.kw.has(Keyword::Vanguard))
            && !ob.cur.kw.has(Keyword::Shackled)
    }

    /// SPEC.md 19.4: whether `b` can block attacker `a`.
    pub(crate) fn can_block(&self, b: Oid, a: Oid) -> bool {
        if b < 1 || b as usize > self.objs.len() || a < 1 || a as usize > self.objs.len() {
            return false;
        }
        let bo = self.obj(b);
        let ao = self.obj(a);
        bo.zone == Zone::Field
            && bo.cur.ctrl == self.active.other()
            && bo.is_unit()
            && !bo.fs.exhausted
            && !bo.cur.kw.has(Keyword::Siegework)
            && ao.zone == Zone::Field
            && ao.fs.attacking
            && (!ao.cur.kw.has(Keyword::Ghostwalk)
                || bo.cur.kw.has(Keyword::Ghostwalk)
                || bo.cur.kw.has(Keyword::Skyhook))
    }

    /// Attacking units with `provoke`, ascending oid.
    pub(crate) fn provokers(&self) -> Vec<Oid> {
        let mut v: Vec<Oid> = self
            .field
            .iter()
            .copied()
            .filter(|&o| self.obj(o).fs.attacking && self.obj(o).cur.kw.has(Keyword::Provoke))
            .collect();
        v.sort_unstable();
        v
    }

    /// `ATTACK` (SPEC.md 19.1, 19.2).
    pub(crate) fn do_attack(&mut self, oids: &[u64]) -> Result<(), &'static str> {
        self.ensure();
        for (i, a) in oids.iter().enumerate() {
            if oids[..i].contains(a) {
                return Err("duplicate-attacker");
            }
        }
        let as_oid = |n: u64| -> Oid { n.min(u64::from(u32::MAX)) as Oid };
        if !oids.iter().all(|&n| self.can_attack(as_oid(n))) {
            return Err("illegal-attacker");
        }
        let chosen: Vec<Oid> = oids.iter().map(|&n| as_oid(n)).collect();
        let missing = self.field.iter().copied().any(|o| {
            self.can_attack(o) && self.obj(o).cur.kw.has(Keyword::Relentless) && !chosen.contains(&o)
        });
        if missing {
            return Err("missing-required-attacker");
        }

        let mut attackers = chosen;
        attackers.sort_unstable();
        if attackers.is_empty() {
            self.decision = None;
            self.cont = Cont::Enter(Step::Main2);
            return Ok(());
        }
        for &o in &attackers {
            self.obj_mut(o).fs.attacking = true;
            self.touch();
            self.ensure();
            if !self.obj(o).cur.kw.has(Keyword::Vigil) {
                self.set_exhausted(o, true);
            }
            self.emit(format!("ATTACK #{o}"));
        }
        for &o in &attackers {
            self.collect_self(o, Event::Attacks, Subject::Obj(o));
        }
        self.begin_round_after(Step::ClashAttack);
        Ok(())
    }

    /// `BLOCK` (SPEC.md 19.3, 19.4).
    pub(crate) fn do_block(&mut self, pairs: &[(u64, u64)]) -> Result<(), &'static str> {
        self.ensure();
        for (i, (b, _)) in pairs.iter().enumerate() {
            if pairs[..i].iter().any(|(x, _)| x == b) {
                return Err("duplicate-blocker");
            }
        }
        let as_oid = |n: u64| -> Oid { n.min(u64::from(u32::MAX)) as Oid };
        let pairs: Vec<(Oid, Oid)> = pairs.iter().map(|&(b, a)| (as_oid(b), as_oid(a))).collect();
        if !pairs.iter().all(|&(b, a)| self.can_block(b, a)) {
            return Err("illegal-blocker");
        }
        let defender = self.active.other();
        for a in self.provokers() {
            if pairs.iter().any(|&(_, x)| x == a) {
                continue;
            }
            let free_blocker = self.field.iter().copied().any(|b| {
                self.obj(b).cur.ctrl == defender
                    && !pairs.iter().any(|&(x, _)| x == b)
                    && self.can_block(b, a)
            });
            if free_blocker {
                return Err("missing-required-block");
            }
        }

        let mut pairs = pairs;
        pairs.sort_unstable();
        for &(b, a) in &pairs {
            self.obj_mut(b).fs.blocking = Some(a);
            let key = |o: Oid| (self.obj(o).ts, o);
            let mut list = self.obj(a).fs.blockers.clone();
            list.push(b);
            list.sort_by_key(|&o| key(o));
            let fa = &mut self.obj_mut(a).fs;
            fa.blockers = list;
            fa.blocked = true;
            self.emit(format!("BLOCK #{b} #{a}"));
        }
        self.touch();
        let mut attackers: Vec<Oid> =
            self.field.iter().copied().filter(|&o| self.obj(o).fs.attacking).collect();
        attackers.sort_unstable();
        let unblocked: Vec<Oid> =
            attackers.iter().copied().filter(|&o| self.obj(o).fs.blockers.is_empty()).collect();
        for &o in &unblocked {
            self.emit(format!("UNBLOCKED #{o}"));
        }
        for &(b, a) in &pairs {
            self.collect_self(b, Event::Blocks, Subject::Obj(a));
        }
        for &a in &attackers {
            if let Some(&first) = self.obj(a).fs.blockers.first() {
                self.collect_self(a, Event::Blocked, Subject::Obj(first));
            }
        }
        for &o in &unblocked {
            self.collect_self(o, Event::Unblocked, Subject::Obj(o));
        }
        self.begin_round_after(Step::ClashBlock);
        Ok(())
    }

    /// Deal the combat damage of one sub-step (SPEC.md 19.5, 19.6).
    pub(crate) fn combat_damage(&mut self, riposte_step: bool) {
        self.ensure();
        let in_combat = self.units_in_combat();
        let dealers: Vec<Oid> = if riposte_step {
            let d: Vec<Oid> =
                in_combat.into_iter().filter(|&o| self.has_kw(o, Keyword::Riposte)).collect();
            self.riposte_dealt = d.clone();
            d
        } else {
            in_combat.into_iter().filter(|o| !self.riposte_dealt.contains(o)).collect()
        };
        let defending = self.active.other();
        let mut triples: Vec<Triple> = Vec::new();
        for u in dealers {
            let e = self.cur_edge(u);
            if e <= 0 {
                continue;
            }
            let fs = &self.obj(u).fs;
            let mut assigns: Vec<(Tgt, i64)> = Vec::new();
            if let Some(a) = fs.blocking {
                assigns.push((Tgt::Obj(a), e));
            } else if fs.attacking {
                if !fs.blocked {
                    assigns.push((Tgt::Player(defending), e));
                } else {
                    let list: Vec<Oid> = fs
                        .blockers
                        .iter()
                        .copied()
                        .filter(|&b| self.on_field(b) && self.obj(b).fs.blocking == Some(u))
                        .collect();
                    if !list.is_empty() {
                        let venom = self.has_kw(u, Keyword::Venom);
                        let mut r = e;
                        for &b in &list {
                            let need = if venom {
                                1
                            } else {
                                (self.cur_core(b) - self.obj(b).fs.wounds).max(0)
                            };
                            let give = r.min(need);
                            assigns.push((Tgt::Obj(b), give));
                            r -= give;
                        }
                        if r > 0 {
                            if self.has_kw(u, Keyword::Pierce) {
                                assigns.push((Tgt::Player(defending), r));
                            } else if let Some(last) = assigns.last_mut() {
                                last.1 += r;
                            }
                        }
                    }
                }
            }
            for (t, n) in assigns {
                if n > 0 {
                    triples.push((self.obj_key(u), self.tgt_key(t), u, t, n));
                }
            }
        }
        triples.sort_by_key(|t| (t.0, t.1));
        for (_, _, u, t, n) in triples {
            self.deal_damage(u, t, n);
        }
    }

    fn obj_key(&self, o: Oid) -> (u8, u64, u64) {
        self.tgt_key(Tgt::Obj(o))
    }
}
