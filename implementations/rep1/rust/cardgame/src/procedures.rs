//! The state-changing procedures of SPEC.md section 17. Each is atomic: no
//! state check or trigger push happens inside it.

use std::rc::Rc;

use crate::model::*;
use crate::state::*;

impl Engine {
    /// Create a new object in limbo with the next oid.
    pub(crate) fn new_object(&mut self, card: Rc<Card>, owner: Player) -> Oid {
        let oid = self.objs.len() as Oid + 1;
        let kw = KwSet::from_specs(&card.keywords);
        self.objs.push(Obj {
            owner,
            zone: Zone::Limbo,
            ts: 0,
            last_ctrl: owner,
            base_ctrl: owner,
            fs: FieldState::default(),
            cur: Current { ctrl: owner, edge: card.edge, core: card.core, kw, stripped: false },
            card,
        });
        oid
    }

    /// Remove an object from the hand/vault/ash/rift list it is in (not the Field).
    pub(crate) fn detach_from_zone(&mut self, o: Oid) {
        let (zone, owner) = {
            let ob = self.obj(o);
            (ob.zone, ob.owner)
        };
        let ps = &mut self.players[owner.idx()];
        match zone {
            Zone::Hand => ps.hand.retain(|&x| x != o),
            Zone::Vault => ps.vault.retain(|&x| x != o),
            Zone::Ash => ps.ash.retain(|&x| x != o),
            Zone::Rift => ps.rift.retain(|&x| x != o),
            Zone::Field | Zone::Limbo => {}
        }
        self.obj_mut(o).zone = Zone::Limbo;
        self.touch();
    }

    pub(crate) fn push_ash(&mut self, o: Oid) {
        let owner = self.obj(o).owner;
        self.players[owner.idx()].ash.push(o);
        self.obj_mut(o).zone = Zone::Ash;
        self.touch();
    }

    pub(crate) fn push_hand(&mut self, o: Oid) {
        let owner = self.obj(o).owner;
        self.players[owner.idx()].hand.push(o);
        self.obj_mut(o).zone = Zone::Hand;
        self.touch();
    }

    pub(crate) fn push_rift(&mut self, o: Oid) {
        let owner = self.obj(o).owner;
        self.players[owner.idx()].rift.push(o);
        self.obj_mut(o).zone = Zone::Rift;
        self.touch();
    }

    /// Take `o` out of combat (SPEC.md 7.5, "Removal from combat").
    pub(crate) fn remove_from_combat(&mut self, o: Oid) {
        let (blocking, attacking, blockers) = {
            let fs = &self.obj(o).fs;
            (fs.blocking, fs.attacking, fs.blockers.clone())
        };
        if let Some(a) = blocking {
            if self.obj(a).zone == Zone::Field {
                self.obj_mut(a).fs.blockers.retain(|&b| b != o);
            }
            self.obj_mut(o).fs.blocking = None;
        }
        if attacking {
            for b in blockers {
                self.obj_mut(b).fs.blocking = None;
            }
            let fs = &mut self.obj_mut(o).fs;
            fs.blockers.clear();
            fs.attacking = false;
            fs.blocked = false;
        }
    }

    /// SPEC.md 17.3 step 4: leave the Field. Returns the controller it had.
    pub(crate) fn leave_field(&mut self, o: Oid) -> Player {
        self.ensure();
        let ctrl = self.obj(o).cur.ctrl;
        self.remove_from_combat(o);
        self.field.retain(|&x| x != o);
        self.records.retain(|r| !(r.src == o && matches!(r.kind, RecKind::Aura { .. })));
        let ob = self.obj_mut(o);
        ob.last_ctrl = ctrl;
        ob.fs = FieldState::default();
        ob.zone = Zone::Limbo;
        self.touch();
        ctrl
    }

    /// SPEC.md 17.17: enter the Field under `ctrl`. During setup nothing is
    /// emitted and no trigger is collected.
    pub(crate) fn enter_field(&mut self, o: Oid, ctrl: Player, setup: bool) {
        let ts = self.new_ts();
        let since = if setup { 0 } else { self.turn };
        {
            let ob = self.obj_mut(o);
            ob.zone = Zone::Field;
            ob.ts = ts;
            ob.base_ctrl = ctrl;
            ob.cur.ctrl = ctrl;
            ob.fs = FieldState { since, ..FieldState::default() };
        }
        self.field.push(o);
        let card = self.obj(o).card.clone();
        for (i, ab) in card.abilities.iter().enumerate() {
            if ab.kind == AbilityKind::Aura {
                let eid = self.next_eid;
                self.next_eid += 1;
                let rts = self.new_ts();
                self.records.push(Record {
                    eid,
                    ts: rts,
                    ctrl,
                    src: o,
                    kind: RecKind::Aura { ability: i },
                    affected: Vec::new(),
                });
            }
        }
        self.touch();
        if setup {
            return;
        }
        self.emit(format!("ARRIVE #{} {}", o, card.id));
        self.collect_self(o, Event::Arrive, Subject::Obj(o));
        if card.ctype == CardType::Unit {
            self.ensure();
            let c = self.obj(o).cur.ctrl;
            self.collect_relative(Event::AllyArrive, Event::EnemyArrive, o, c, Subject::Obj(o));
        }
    }

    fn finish_death(&mut self, o: Oid, verb: &str) {
        let card = self.obj(o).card.clone();
        let ctrl = self.leave_field(o);
        self.push_ash(o);
        self.emit(format!("{verb} #{} {}", o, card.id));
        self.collect_from(o, ctrl, Event::Dies, Subject::Obj(o));
        self.collect_from(o, ctrl, Event::Leave, Subject::Obj(o));
        if card.ctype == CardType::Unit {
            self.collect_relative(Event::AllyDies, Event::EnemyDies, o, ctrl, Subject::Obj(o));
        }
    }

    /// SPEC.md 17.3.
    pub(crate) fn destroy(&mut self, o: Oid) {
        self.ensure();
        if !self.on_field(o) {
            return;
        }
        let ob = self.obj(o);
        if ob.cur.kw.has(Keyword::Tenacity) && !ob.fs.tenacity_used {
            let ob = self.obj_mut(o);
            ob.fs.tenacity_used = true;
            ob.fs.wounds = 0;
            ob.fs.doomed = false;
            self.touch();
            self.emit(format!("TENACITY #{o}"));
            return;
        }
        self.finish_death(o, "DESTROY");
    }

    /// SPEC.md 17.4.
    pub(crate) fn sacrifice(&mut self, o: Oid) {
        if !self.on_field(o) {
            return;
        }
        self.finish_death(o, "SACRIFICE");
    }

    /// SPEC.md 17.5.
    pub(crate) fn exile(&mut self, o: Oid) {
        let zone = self.obj(o).zone;
        if zone == Zone::Limbo {
            return;
        }
        let card_id = self.obj(o).card.id.clone();
        let mut left_ctrl = None;
        if zone == Zone::Field {
            left_ctrl = Some(self.leave_field(o));
        } else {
            self.detach_from_zone(o);
        }
        self.push_rift(o);
        self.emit(format!("EXILE #{} {} {}", o, card_id, zone.name()));
        if let Some(c) = left_ctrl {
            self.collect_from(o, c, Event::Leave, Subject::Obj(o));
        }
    }

    /// SPEC.md 17.6.
    pub(crate) fn bounce(&mut self, o: Oid) {
        if !self.on_field(o) {
            return;
        }
        let card_id = self.obj(o).card.id.clone();
        let c = self.leave_field(o);
        self.push_hand(o);
        self.emit(format!("BOUNCE #{} {}", o, card_id));
        self.collect_from(o, c, Event::Leave, Subject::Obj(o));
    }

    /// SPEC.md 17.7: one draw. Returns false when the Vault was empty.
    pub(crate) fn draw_one(&mut self, p: Player) -> bool {
        match self.players[p.idx()].vault.pop_front() {
            None => {
                self.emit(format!("DRAW-EMPTY {}", p.name()));
                let ps = &mut self.players[p.idx()];
                if ps.lost.is_none() {
                    ps.lost = Some(Reason::Vault);
                }
                false
            }
            Some(o) => {
                self.push_hand(o);
                let id = self.obj(o).card.id.clone();
                self.emit(format!("DRAW {} #{} {}", p.name(), o, id));
                if self.triggers_on {
                    self.collect_player(Some(Event::YouDraw), None, p, Subject::Obj(o));
                }
                true
            }
        }
    }

    /// SPEC.md 17.8: discard the card at hand position 1.
    pub(crate) fn discard_one(&mut self, p: Player) {
        if self.players[p.idx()].hand.is_empty() {
            return;
        }
        let o = self.players[p.idx()].hand.remove(0);
        self.obj_mut(o).zone = Zone::Limbo;
        self.push_ash(o);
        let id = self.obj(o).card.id.clone();
        self.emit(format!("DISCARD {} #{} {}", p.name(), o, id));
    }

    /// SPEC.md 17.9: mill the top Vault card.
    pub(crate) fn mill_one(&mut self, p: Player) {
        if let Some(o) = self.players[p.idx()].vault.pop_front() {
            self.obj_mut(o).zone = Zone::Limbo;
            self.push_ash(o);
            let id = self.obj(o).card.id.clone();
            self.emit(format!("MILL {} #{} {}", p.name(), o, id));
        }
    }

    /// SPEC.md 17.10.
    pub(crate) fn change_spire(&mut self, p: Player, delta: i64) {
        if delta == 0 {
            return;
        }
        let ps = &mut self.players[p.idx()];
        ps.spire += delta;
        let new = ps.spire;
        self.touch();
        self.emit(format!("SPIRE {} {:+} {}", p.name(), delta, new));
        if delta < 0 {
            self.collect_player(
                Some(Event::SpireLoss),
                Some(Event::EnemySpireLoss),
                p,
                Subject::Player(p),
            );
        }
    }

    /// SPEC.md 17.11.
    pub(crate) fn gain_ember(&mut self, p: Player, n: i64) {
        if n <= 0 {
            return;
        }
        let ps = &mut self.players[p.idx()];
        ps.ember += n;
        let new = ps.ember;
        self.touch();
        self.emit(format!("EMBERGAIN {} {} {}", p.name(), n, new));
    }

    /// SPEC.md 17.12.
    pub(crate) fn raise_cap(&mut self, p: Player, n: i64) {
        if n <= 0 {
            return;
        }
        let maxcap = self.cfg.maxcap;
        let ps = &mut self.players[p.idx()];
        ps.cap = (ps.cap + n).min(maxcap);
        let cap = ps.cap;
        self.emit(format!("CAP {} {} {}", p.name(), n, cap));
    }

    /// SPEC.md 17.14.
    pub(crate) fn add_counters(&mut self, o: Oid, delta: i64) {
        if !self.on_field(o) {
            return;
        }
        let ob = self.obj_mut(o);
        let old = ob.fs.counters;
        let new = (old + delta).max(0);
        ob.fs.counters = new;
        if new != old {
            self.touch();
            self.emit(format!("COUNTERS #{} {:+} {}", o, new - old, new));
        }
    }

    /// SPEC.md 17.15.
    pub(crate) fn set_exhausted(&mut self, o: Oid, exhausted: bool) {
        if !self.on_field(o) {
            return;
        }
        let ob = self.obj_mut(o);
        if ob.fs.exhausted != exhausted {
            ob.fs.exhausted = exhausted;
            self.touch();
            self.emit(format!("{} #{}", if exhausted { "EXHAUST" } else { "READY" }, o));
        }
    }

    /// SPEC.md 17.16.
    pub(crate) fn doom(&mut self, o: Oid) {
        if !self.on_field(o) || !self.obj(o).is_unit() {
            return;
        }
        self.obj_mut(o).fs.doomed = true;
        self.touch();
        self.emit(format!("DOOM #{o}"));
    }

    /// SPEC.md 17.1 and 15.2: deal `n` damage from `src` to `tgt`.
    pub(crate) fn deal_damage(&mut self, src: Oid, tgt: Tgt, n: i64) {
        if n <= 0 {
            return;
        }
        self.ensure();
        let mut m = n;
        match tgt {
            Tgt::Obj(t) => {
                if !self.on_field(t) || !self.obj(t).is_unit() {
                    return;
                }
                let ob = self.obj_mut(t);
                if ob.cur.kw.has(Keyword::Plating) {
                    m = (m - ob.cur.kw.plating()).max(0);
                }
                let u = ob.fs.ward.min(m);
                ob.fs.ward -= u;
                m -= u;
            }
            Tgt::Player(p) => {
                let ps = &mut self.players[p.idx()];
                let u = ps.shield.min(m);
                ps.shield -= u;
                m -= u;
            }
            Tgt::Entry(_) => return,
        }
        let prevented = n - m;
        if prevented > 0 {
            let t = self.render_tgt(tgt);
            self.emit(format!("PREVENT {t} {prevented}"));
            self.touch();
        }
        if m <= 0 {
            return;
        }
        let t = self.render_tgt(tgt);
        self.emit(format!("DAMAGE #{src} {t} {m}"));
        match tgt {
            Tgt::Obj(o) => {
                self.obj_mut(o).fs.wounds += m;
                self.touch();
            }
            Tgt::Player(p) => {
                let ps = &mut self.players[p.idx()];
                ps.spire -= m;
                let new = ps.spire;
                self.touch();
                self.emit(format!("SPIRE {} -{} {}", p.name(), m, new));
                self.collect_player(
                    Some(Event::SpireLoss),
                    Some(Event::EnemySpireLoss),
                    p,
                    Subject::Player(p),
                );
            }
            Tgt::Entry(_) => {}
        }
        self.ensure();
        let src_unit_on_field = self.on_field(src) && self.obj(src).is_unit();
        if let Tgt::Obj(o) = tgt {
            if src_unit_on_field && self.obj(src).cur.kw.has(Keyword::Venom) {
                self.obj_mut(o).fs.doomed = true;
                self.touch();
                self.emit(format!("DOOM #{o}"));
            }
        }
        if src_unit_on_field && self.obj(src).cur.kw.has(Keyword::Siphon) {
            let c = self.obj(src).cur.ctrl;
            let ps = &mut self.players[c.idx()];
            ps.spire += m;
            let new = ps.spire;
            self.touch();
            self.emit(format!("SPIRE {} +{} {}", c.name(), m, new));
        }
        if let Tgt::Obj(o) = tgt {
            self.collect_self(o, Event::Damaged, Subject::Obj(src));
        }
        if self.on_field(src) {
            let subj = match tgt {
                Tgt::Obj(o) => Subject::Obj(o),
                Tgt::Player(p) => Subject::Player(p),
                Tgt::Entry(_) => Subject::None,
            };
            self.collect_self(src, Event::DealsDamage, subj);
        }
    }

    /// SPEC.md 17.20: negate a Chain entry.
    pub(crate) fn negate_entry(&mut self, cid: Cid) {
        let Some(pos) = self.chain.iter().position(|e| e.cid == cid) else {
            return;
        };
        let e = self.chain.remove(pos);
        self.emit(format!("NEGATE ~{cid}"));
        if matches!(e.kind, EntryKind::Rite | EntryKind::Unit | EntryKind::Relic) {
            self.push_ash(e.src);
            let id = self.obj(e.src).card.id.clone();
            self.emit(format!("SPENT #{} {}", e.src, id));
        }
    }

    /// SPEC.md 17.21: dig.
    pub(crate) fn dig(&mut self, p: Player, k: i64, filters: &[Filter], ctrl: Player, src: Oid) {
        self.ensure();
        let n = if k <= 0 { 0 } else { (k as usize).min(self.players[p.idx()].vault.len()) };
        let mut list: Vec<Oid> = (0..n)
            .map(|_| self.players[p.idx()].vault.pop_front().expect("vault length checked"))
            .collect();
        for &o in &list {
            self.obj_mut(o).zone = Zone::Limbo;
        }
        let hit = list.iter().position(|&o| self.filters_ok(o, filters, ctrl, src));
        match hit {
            Some(i) => {
                let o = list.remove(i);
                self.push_hand(o);
                let id = self.obj(o).card.id.clone();
                self.emit(format!("DIG {} #{} {}", p.name(), o, id));
            }
            None => self.emit(format!("DIG-MISS {}", p.name())),
        }
        for o in list {
            self.players[p.idx()].vault.push_back(o);
            self.obj_mut(o).zone = Zone::Vault;
            let id = self.obj(o).card.id.clone();
            self.emit(format!("BOTTOM {} #{} {}", p.name(), o, id));
        }
        self.touch();
    }
}
