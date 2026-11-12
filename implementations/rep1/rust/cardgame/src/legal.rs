//! The `LEGAL` directive (SPEC.md sections 21 and 23.2).

use crate::model::*;
use crate::state::*;

impl Engine {
    /// Print the `LEGAL` block for the current decision point.
    pub(crate) fn legal_block(&mut self) {
        self.ensure();
        let Some((p, dec)) = self.decision else {
            self.raw("LEGAL BEGIN - over");
            self.raw("LEGAL END");
            return;
        };
        self.raw(format!("LEGAL BEGIN {} {}", p.name(), dec.name()));
        match dec {
            Decision::Priority => self.legal_priority(p),
            Decision::Attackers => {
                let mut can: Vec<Oid> =
                    self.field.iter().copied().filter(|&o| self.can_attack(o)).collect();
                can.sort_unstable();
                for &o in &can {
                    self.raw(format!("CANATTACK #{o}"));
                }
                for &o in &can {
                    if self.obj(o).cur.kw.has(Keyword::Relentless) {
                        self.raw(format!("MUSTATTACK #{o}"));
                    }
                }
            }
            Decision::Blockers => {
                let mut all: Vec<Oid> = self.field.clone();
                all.sort_unstable();
                for &b in &all {
                    for &a in &all {
                        if self.can_block(b, a) {
                            self.raw(format!("CANBLOCK #{b} #{a}"));
                        }
                    }
                }
                for a in self.provokers() {
                    self.raw(format!("MUSTBLOCK #{a}"));
                }
            }
        }
        self.raw("LEGAL END");
    }

    fn legal_priority(&mut self, p: Player) {
        self.raw("PASS");
        let hand = self.players[p.idx()].hand.clone();
        for (i, &o) in hand.iter().enumerate() {
            let card = self.obj(o).card.clone();
            if !self.play_timing_ok(p, &card) {
                continue;
            }
            let cost = (card.cost - self.cheaper_total(p, &card)).max(0);
            if self.players[p.idx()].ember < cost {
                continue;
            }
            let specs = Self::play_specs(&card);
            for tuple in self.target_tuples(&specs, p, o) {
                let mut line = format!("PLAY {} {}", i + 1, card.id);
                for t in tuple {
                    line.push(' ');
                    line.push_str(&self.render_tgt(t));
                }
                self.raw(line);
            }
        }
        let mut mine: Vec<Oid> = self
            .field
            .iter()
            .copied()
            .filter(|&o| self.obj(o).cur.ctrl == p && !self.obj(o).cur.stripped)
            .collect();
        mine.sort_unstable();
        for o in mine {
            let card = self.obj(o).card.clone();
            for (i, ab) in card.abilities.iter().enumerate() {
                if ab.kind != AbilityKind::Act {
                    continue;
                }
                let idx = i + 1;
                if !ab.cost.iter().all(|c| self.cost_payable(c, p, o, idx)) {
                    continue;
                }
                for tuple in self.target_tuples(&ab.targets, p, o) {
                    let mut line = format!("ACT #{o} {idx}");
                    for t in tuple {
                        line.push(' ');
                        line.push_str(&self.render_tgt(t));
                    }
                    self.raw(line);
                }
            }
        }
    }
}
