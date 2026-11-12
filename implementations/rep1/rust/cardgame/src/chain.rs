//! Playing cards, activating abilities and resolving Chain entries
//! (SPEC.md sections 11 and 12).

use std::rc::Rc;

use crate::eval::Ctx;
use crate::matchfile::TargetToken;
use crate::model::*;
use crate::state::*;

impl Engine {
    /// Convert a script target token to a target (`None` if it names no object).
    fn token_to_tgt(&self, t: TargetToken) -> Option<Tgt> {
        match t {
            TargetToken::Player(p) => Some(Tgt::Player(p)),
            TargetToken::Object(n) => {
                if n >= 1 && n <= self.objs.len() as u64 {
                    Some(Tgt::Obj(n as Oid))
                } else {
                    None
                }
            }
            TargetToken::Entry(n) => Some(Tgt::Entry(n.min(u64::from(u32::MAX)) as Cid)),
        }
    }

    /// Check the target tokens against the specs: count, then legality and
    /// distinctness (SPEC.md 24, checks 7 and 8).
    fn check_targets(
        &mut self,
        specs: &[TSpec],
        tokens: &[TargetToken],
        ctrl: Player,
        src: Oid,
    ) -> Result<Vec<Tgt>, &'static str> {
        if tokens.len() != specs.len() {
            return Err("bad-target-count");
        }
        let mut tgts: Vec<Tgt> = Vec::new();
        let mut ok = true;
        for (i, tok) in tokens.iter().enumerate() {
            match self.token_to_tgt(*tok) {
                Some(t) if !tgts.contains(&t) => {
                    if !self.target_legal(&specs[i], t, ctrl, src, 0) {
                        ok = false;
                    }
                    tgts.push(t);
                }
                _ => ok = false,
            }
        }
        if ok {
            Ok(tgts)
        } else {
            Err("illegal-target")
        }
    }

    fn render_targets(&self, tgts: &[Tgt]) -> String {
        let mut s = String::new();
        for t in tgts {
            s.push(' ');
            s.push_str(&self.render_tgt(*t));
        }
        s
    }

    /// Whether `card` may be played by `p` right now (SPEC.md 11.1).
    pub(crate) fn play_timing_ok(&self, p: Player, card: &Card) -> bool {
        let swift = card.ctype == CardType::Rite && card.has_printed(Keyword::Swift);
        swift
            || (p == self.active
                && matches!(self.step, Step::Main1 | Step::Main2)
                && self.chain.is_empty())
    }

    /// Specs of the targets a played card takes.
    pub(crate) fn play_specs(card: &Card) -> Rc<Vec<TSpec>> {
        if card.ctype == CardType::Rite {
            card.abilities[0].targets.clone()
        } else {
            Rc::new(Vec::new())
        }
    }

    /// `PLAY` (SPEC.md 11.2). On error nothing has changed.
    pub(crate) fn do_play(
        &mut self,
        p: Player,
        pos: u64,
        tokens: &[TargetToken],
    ) -> Result<(), &'static str> {
        let hand_len = self.players[p.idx()].hand.len() as u64;
        if pos == 0 || pos > hand_len {
            return Err("no-such-card");
        }
        let o = self.players[p.idx()].hand[pos as usize - 1];
        let card = self.obj(o).card.clone();
        if !self.play_timing_ok(p, &card) {
            return Err("bad-timing");
        }
        let specs = Self::play_specs(&card);
        let tgts = self.check_targets(&specs, tokens, p, o)?;
        let cost = (card.cost - self.cheaper_total(p, &card)).max(0);
        if self.players[p.idx()].ember < cost {
            return Err("cannot-afford");
        }

        self.detach_from_zone(o);
        let cid = self.next_cid;
        self.next_cid += 1;
        let kind = match card.ctype {
            CardType::Rite => EntryKind::Rite,
            CardType::Unit => EntryKind::Unit,
            CardType::Relic => EntryKind::Relic,
        };
        let line = format!(
            "PLAY {} ~{} #{} {}{}",
            p.name(),
            cid,
            o,
            card.id,
            self.render_targets(&tgts)
        );
        self.emit(line);
        if cost > 0 {
            self.players[p.idx()].ember -= cost;
            self.touch();
            self.emit(format!("PAY {} ember {}", p.name(), cost));
        }
        if kind == EntryKind::Rite {
            self.collect_player(
                Some(Event::YouPlayRite),
                Some(Event::EnemyPlaysRite),
                p,
                Subject::Obj(o),
            );
        }
        self.chain.push(Entry {
            cid,
            kind,
            ctrl: p,
            src: o,
            idx: 0,
            targets: tgts.into_iter().map(|tgt| TSlot { tgt, removed: false }).collect(),
            specs,
            subject: Subject::None,
            delayed: None,
        });
        Ok(())
    }

    /// Whether a cost item is payable (SPEC.md 11.3 step 4).
    pub(crate) fn cost_payable(&self, item: &CostItem, p: Player, o: Oid, idx: usize) -> bool {
        let ob = self.obj(o);
        match *item {
            CostItem::Ember(n) => self.players[p.idx()].ember >= n,
            CostItem::Spire(_) => true,
            CostItem::Discard(n) => self.players[p.idx()].hand.len() as i64 >= n,
            CostItem::Exhaust => {
                ob.zone == Zone::Field
                    && !ob.fs.exhausted
                    && (!self.is_settling(o) || ob.cur.kw.has(Keyword::Vanguard))
            }
            CostItem::SacSelf => ob.zone == Zone::Field,
            CostItem::Counters(n) => ob.zone == Zone::Field && ob.fs.counters >= n,
            CostItem::Once => !ob.fs.once_used.contains(&idx),
        }
    }

    fn pay_cost(&mut self, item: &CostItem, p: Player, o: Oid, idx: usize) {
        match *item {
            CostItem::Ember(n) => {
                if n > 0 {
                    self.players[p.idx()].ember -= n;
                    self.touch();
                    self.emit(format!("PAY {} ember {}", p.name(), n));
                }
            }
            CostItem::Spire(n) => {
                if n > 0 {
                    self.emit(format!("PAY {} spire {}", p.name(), n));
                }
                self.change_spire(p, -n);
            }
            CostItem::Discard(n) => {
                for _ in 0..n.max(0) {
                    if self.players[p.idx()].hand.is_empty() {
                        break;
                    }
                    self.discard_one(p);
                }
            }
            CostItem::Exhaust => self.set_exhausted(o, true),
            CostItem::SacSelf => self.sacrifice(o),
            CostItem::Counters(n) => self.add_counters(o, -n),
            CostItem::Once => {
                self.obj_mut(o).fs.once_used.push(idx);
                self.touch();
            }
        }
    }

    /// `ACT` (SPEC.md 11.3). On error nothing has changed.
    pub(crate) fn do_act(
        &mut self,
        p: Player,
        oid: u64,
        index: u64,
        tokens: &[TargetToken],
    ) -> Result<(), &'static str> {
        self.ensure();
        if oid < 1 || oid > self.objs.len() as u64 {
            return Err("no-such-object");
        }
        let o = oid as Oid;
        if !self.on_field(o) || self.obj(o).cur.ctrl != p {
            return Err("no-such-object");
        }
        let card = self.obj(o).card.clone();
        if index < 1
            || index > card.abilities.len() as u64
            || card.abilities[index as usize - 1].kind != AbilityKind::Act
            || self.obj(o).cur.stripped
        {
            return Err("no-such-ability");
        }
        let idx = index as usize;
        let ab = &card.abilities[idx - 1];
        let tgts = self.check_targets(&ab.targets, tokens, p, o)?;
        if !ab.cost.iter().all(|c| self.cost_payable(c, p, o, idx)) {
            return Err("cost-unpayable");
        }

        let cid = self.next_cid;
        self.next_cid += 1;
        let line = format!("ACTIVATE {} ~{} #{} {}{}", p.name(), cid, o, idx, self.render_targets(&tgts));
        self.emit(line);
        for item in &ab.cost {
            self.pay_cost(item, p, o, idx);
        }
        self.chain.push(Entry {
            cid,
            kind: EntryKind::Ability,
            ctrl: p,
            src: o,
            idx,
            targets: tgts.into_iter().map(|tgt| TSlot { tgt, removed: false }).collect(),
            specs: ab.targets.clone(),
            subject: Subject::None,
            delayed: None,
        });
        Ok(())
    }

    /// Resolve the top Chain entry (SPEC.md 11.6).
    pub(crate) fn resolve_top(&mut self) {
        let entry = self.chain.last().cloned().expect("chain is not empty");
        let cid = entry.cid;
        self.emit(format!("RESOLVE ~{cid}"));
        self.ensure();

        let mut slots = entry.targets.clone();
        for (i, slot) in slots.iter_mut().enumerate() {
            let legal = match entry.specs.get(i) {
                Some(spec) => self.target_legal(spec, slot.tgt, entry.ctrl, entry.src, cid),
                None => false,
            };
            if !legal {
                slot.removed = true;
            }
        }
        let fizzled = !slots.is_empty() && slots.iter().all(|s| s.removed);
        if fizzled {
            self.emit(format!("FIZZLE ~{cid}"));
        } else {
            match entry.kind {
                EntryKind::Unit | EntryKind::Relic => {
                    self.remove_entry(cid);
                    self.enter_field(entry.src, entry.ctrl, false);
                }
                EntryKind::Rite | EntryKind::Ability | EntryKind::Trigger => {
                    let effects: Rc<Vec<Effect>> = match &entry.delayed {
                        Some(d) => d.effects.clone(),
                        None => {
                            let card = self.obj(entry.src).card.clone();
                            let i = if entry.kind == EntryKind::Rite { 0 } else { entry.idx - 1 };
                            card.abilities[i].effects.clone()
                        }
                    };
                    let mut ctx = Ctx {
                        ctrl: entry.ctrl,
                        src: entry.src,
                        subject: entry.subject,
                        targets: slots,
                        specs: entry.specs.clone(),
                        that: Vec::new(),
                    };
                    self.exec_effects(&effects, &mut ctx);
                }
            }
        }
        self.remove_entry(cid);
        if entry.kind == EntryKind::Rite {
            self.push_ash(entry.src);
            let id = self.obj(entry.src).card.id.clone();
            self.emit(format!("SPENT #{} {}", entry.src, id));
        } else if fizzled && matches!(entry.kind, EntryKind::Unit | EntryKind::Relic) {
            self.push_ash(entry.src);
        }
    }

    fn remove_entry(&mut self, cid: Cid) {
        if let Some(pos) = self.chain.iter().position(|e| e.cid == cid) {
            self.chain.remove(pos);
        }
    }
}
