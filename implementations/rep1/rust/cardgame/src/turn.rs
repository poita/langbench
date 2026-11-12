//! Turn structure, priority rounds, state checks and draining
//! (SPEC.md sections 9, 10, 18 and 20).

use crate::model::*;
use crate::state::*;

impl Engine {
    // ----------------------------------------------------------------- end

    /// End the match: `LOSE` lines, then the single `RESULT` line (SPEC.md 20).
    pub(crate) fn end_match(&mut self) {
        let lost = [self.players[0].lost, self.players[1].lost];
        for p in Player::BOTH {
            if let Some(r) = lost[p.idx()] {
                self.emit(format!("LOSE {} {}", p.name(), r.name()));
            }
        }
        let (winner, reason) = match (lost[0], lost[1]) {
            (Some(a), Some(_)) => (None, a.name()),
            (Some(a), None) => (Some(Player::B), a.name()),
            (None, Some(b)) => (Some(Player::A), b.name()),
            (None, None) => unreachable!("end_match needs a loser"),
        };
        self.emit(format!("RESULT {} {}", winner.map_or("draw", Player::name), reason));
        self.result = Some(MatchResult { winner, reason });
        self.decision = None;
    }

    // ------------------------------------------------------- state checks

    /// One run of the state checks (SPEC.md 18). Reports whether it acted.
    fn state_checks(&mut self) -> bool {
        for p in Player::BOTH {
            let ps = &mut self.players[p.idx()];
            if ps.spire <= 0 && ps.lost.is_none() {
                ps.lost = Some(Reason::Spire);
            }
        }
        if self.players.iter().any(|p| p.lost.is_some()) {
            self.end_match();
            return true;
        }
        self.ensure();
        let doomed: Vec<Oid> = self
            .field
            .iter()
            .copied()
            .filter(|&o| {
                let ob = self.obj(o);
                ob.is_unit() && (ob.cur.core <= ob.fs.wounds || ob.fs.doomed)
            })
            .collect();
        if doomed.is_empty() {
            return false;
        }
        for o in doomed {
            self.destroy(o);
        }
        true
    }

    /// `settle` (SPEC.md 10.5). Reports whether anything happened.
    pub(crate) fn settle(&mut self) -> bool {
        let mut acted = false;
        loop {
            let a = self.state_checks();
            if self.result.is_some() {
                return true;
            }
            let b = self.push_triggers();
            acted |= a || b;
            if !a && !b {
                return acted;
            }
        }
    }

    /// `drain` (SPEC.md 10.6).
    pub(crate) fn drain(&mut self) {
        loop {
            self.settle();
            if self.result.is_some() || self.chain.is_empty() {
                return;
            }
            self.resolve_top();
        }
    }

    // ----------------------------------------------------------- the loop

    /// Run forward until a decision is needed or the match ends.
    pub(crate) fn run(&mut self) {
        loop {
            if self.result.is_some() {
                self.decision = None;
                return;
            }
            match self.cont {
                Cont::Waiting => return,
                Cont::TurnStart => {
                    self.emit(format!("TURN {} {}", self.turn, self.active.name()));
                    self.cont = Cont::Enter(Step::Dawn);
                }
                Cont::Enter(step) => self.enter_step(step),
            }
        }
    }

    fn start_round(&mut self, step: Step) {
        self.round_step = step;
        self.passes = 0;
        self.settle();
        if self.result.is_some() {
            return;
        }
        self.holder = self.active;
        self.decision = Some((self.holder, Decision::Priority));
        self.cont = Cont::Waiting;
    }

    fn enter_step(&mut self, step: Step) {
        self.step = step;
        self.emit(format!("PHASE {}", step.name()));
        match step {
            Step::Dawn => {
                self.dawn();
                self.drain();
                self.cont = Cont::Enter(Step::Draw);
            }
            Step::Draw => {
                if self.turn != 1 {
                    let a = self.active;
                    self.draw_one(a);
                }
                self.drain();
                self.cont = Cont::Enter(Step::Main1);
            }
            Step::Main1 | Step::Main2 => self.start_round(step),
            Step::ClashAttack => {
                self.riposte_dealt.clear();
                self.settle();
                if self.result.is_some() {
                    return;
                }
                self.decision = Some((self.active, Decision::Attackers));
                self.cont = Cont::Waiting;
            }
            Step::ClashBlock => {
                self.settle();
                if self.result.is_some() {
                    return;
                }
                self.decision = Some((self.active.other(), Decision::Blockers));
                self.cont = Cont::Waiting;
            }
            Step::ClashRiposte => {
                self.combat_damage(true);
                self.start_round(step);
            }
            Step::ClashDamage => {
                self.combat_damage(false);
                self.start_round(step);
            }
            Step::ClashEnd => {
                self.ensure();
                let in_combat: Vec<Oid> = self.units_in_combat();
                for o in in_combat {
                    self.collect_self(o, Event::EndOfCombat, Subject::Obj(o));
                }
                self.fire_delayed(When::EndOfCombat);
                self.start_round(step);
            }
            Step::DuskTrigger => {
                self.collect_turn_event(Event::TurnEnd, Event::YourTurnEnd);
                self.fire_delayed(When::TurnEnd);
                self.start_round(step);
            }
            Step::DuskDiscard => {
                let a = self.active;
                while self.players[a.idx()].hand.len() > self.cfg.handmax {
                    self.discard_one(a);
                }
                self.drain();
                self.cont = Cont::Enter(Step::DuskCleanup);
            }
            Step::DuskCleanup => {
                self.cleanup();
                self.drain();
                if self.result.is_some() {
                    return;
                }
                self.turn += 1;
                self.active = self.active.other();
                self.touch();
                if self.turn > self.cfg.turnlimit {
                    self.emit("RESULT draw turn-limit");
                    self.result = Some(MatchResult { winner: None, reason: "turn-limit" });
                    self.decision = None;
                } else {
                    self.cont = Cont::TurnStart;
                }
            }
        }
    }

    /// Where the run goes after a step's priority round ends.
    fn after_round(&mut self) {
        let next = match self.round_step {
            Step::Main1 => Step::ClashAttack,
            Step::ClashAttack => Step::ClashBlock,
            Step::ClashBlock => {
                if self.any_riposte_in_combat() {
                    Step::ClashRiposte
                } else {
                    Step::ClashDamage
                }
            }
            Step::ClashRiposte => Step::ClashDamage,
            Step::ClashDamage => Step::ClashEnd,
            Step::ClashEnd => {
                self.clear_combat();
                Step::Main2
            }
            Step::Main2 => Step::DuskTrigger,
            Step::DuskTrigger => Step::DuskDiscard,
            other => unreachable!("no priority round in {other:?}"),
        };
        self.decision = None;
        self.cont = Cont::Enter(next);
    }

    // -------------------------------------------------------------- steps

    fn dawn(&mut self) {
        let a = self.active;
        let maxcap = self.cfg.maxcap;
        {
            let ps = &mut self.players[a.idx()];
            ps.cap = (ps.cap + 1).min(maxcap);
        }
        for p in Player::BOTH {
            let ps = &mut self.players[p.idx()];
            ps.ember = ps.cap;
            let (e, c) = (ps.ember, ps.cap);
            self.emit(format!("EMBER {} {} {}", p.name(), e, c));
        }
        self.touch();
        self.ensure();
        for i in 0..self.field.len() {
            let o = self.field[i];
            if self.obj(o).cur.ctrl == a {
                self.set_exhausted(o, false);
            }
        }
        for i in 0..self.field.len() {
            let o = self.field[i];
            let fs = &mut self.obj_mut(o).fs;
            fs.tenacity_used = false;
            fs.once_used.clear();
        }
        self.touch();
        self.collect_turn_event(Event::TurnStart, Event::YourTurnStart);
        self.fire_delayed(When::YourNextTurnStart);
    }

    /// `dusk-cleanup` (SPEC.md 9.7).
    fn cleanup(&mut self) {
        let turn = self.turn;
        for i in 0..self.field.len() {
            let o = self.field[i];
            let fs = &mut self.obj_mut(o).fs;
            fs.wounds = 0;
            fs.doomed = false;
            fs.ward = 0;
        }
        for p in &mut self.players {
            p.shield = 0;
        }
        let mut controlled: Vec<Oid> = Vec::new();
        for r in &self.records {
            if matches!(r.kind, RecKind::Control) {
                controlled.extend(r.affected.iter().copied());
            }
        }
        for o in controlled {
            if self.on_field(o) {
                self.obj_mut(o).fs.since = turn;
            }
        }
        self.records.retain(|r| matches!(r.kind, RecKind::Aura { .. }));
        self.delayed.retain(|d| d.when == When::YourNextTurnStart);
        self.touch();
    }

    // ------------------------------------------------------------ actions

    /// `PASS` (SPEC.md 10.3).
    pub(crate) fn act_pass(&mut self, p: Player) {
        self.emit(format!("PASS {}", p.name()));
        self.passes += 1;
        if self.passes == 1 {
            self.holder = self.holder.other();
            self.decision = Some((self.holder, Decision::Priority));
        } else if !self.chain.is_empty() {
            self.passes = 0;
            self.resolve_top();
            self.settle();
            self.holder = self.active;
            self.decision = Some((self.holder, Decision::Priority));
        } else {
            self.after_round();
        }
    }

    /// Bookkeeping after an accepted `PLAY`/`ACT` (SPEC.md 10.4).
    pub(crate) fn after_priority_action(&mut self, actor: Player) {
        self.passes = 0;
        self.holder = actor;
        if self.settle() {
            self.passes = 0;
            self.holder = self.active;
        }
        self.decision = Some((self.holder, Decision::Priority));
    }

    /// Start the priority round that follows an attack or block declaration.
    pub(crate) fn begin_round_after(&mut self, step: Step) {
        self.start_round(step);
    }
}
