//! The inspection blocks: `DUMP`, `VAULT` and `CARD` (SPEC.md section 23).

use crate::model::*;
use crate::state::*;

impl Engine {
    /// Print the `STATE` block.
    pub(crate) fn dump_block(&mut self) {
        self.ensure();
        self.raw("STATE BEGIN");
        let dec = match self.decision {
            Some((p, d)) => format!("{} {}", p.name(), d.name()),
            None => "- over".to_string(),
        };
        self.raw(format!(
            "turn {} active {} phase {} decision {}",
            self.turn,
            self.active.name(),
            self.step.name(),
            dec
        ));
        if let Some(r) = self.result {
            self.raw(format!("result {} {}", r.winner.map_or("draw", Player::name), r.reason));
        }
        for p in Player::BOTH {
            let ps = &self.players[p.idx()];
            let line = format!(
                "player {} spire {} ember {} cap {} vault {} hand {} ash {} rift {}",
                p.name(),
                ps.spire,
                ps.ember,
                ps.cap,
                ps.vault.len(),
                ps.hand.len(),
                ps.ash.len(),
                ps.rift.len()
            );
            self.raw(line);
        }
        for p in Player::BOTH {
            for (i, &o) in self.players[p.idx()].hand.clone().iter().enumerate() {
                let line = format!("hand {} {} #{} {}", p.name(), i + 1, o, self.obj(o).card.id);
                self.raw(line);
            }
        }
        for p in Player::BOTH {
            for o in self.field.clone() {
                if self.obj(o).cur.ctrl == p {
                    let line = self.field_line(p, o);
                    self.raw(line);
                }
            }
        }
        for p in Player::BOTH {
            for (i, &o) in self.players[p.idx()].ash.clone().iter().enumerate() {
                let line = format!("ash {} {} #{} {}", p.name(), i + 1, o, self.obj(o).card.id);
                self.raw(line);
            }
        }
        for p in Player::BOTH {
            for (i, &o) in self.players[p.idx()].rift.clone().iter().enumerate() {
                let line = format!("rift {} {} #{} {}", p.name(), i + 1, o, self.obj(o).card.id);
                self.raw(line);
            }
        }
        for (i, e) in self.chain.clone().iter().enumerate() {
            let mut line =
                format!("chain {} ~{} {} {} #{} {}", i + 1, e.cid, e.ctrl.name(), e.kind.name(), e.src, e.idx);
            for s in &e.targets {
                line.push(' ');
                line.push_str(&if s.removed { "-".to_string() } else { self.render_tgt(s.tgt) });
            }
            self.raw(line);
        }
        self.effect_lines();
        for d in self.delayed.clone() {
            let mut line = format!("delayed {} {} {}", d.ts, d.ctrl.name(), d.when.name());
            for t in &d.targets {
                line.push(' ');
                line.push_str(&self.render_tgt(*t));
            }
            self.raw(line);
        }
        self.raw("STATE END");
    }

    fn field_line(&self, p: Player, o: Oid) -> String {
        let ob = self.obj(o);
        let body = if ob.is_unit() {
            format!("{}/{}", ob.cur.edge, ob.cur.core)
        } else {
            "-/-".to_string()
        };
        let mut flags: Vec<String> = Vec::new();
        if ob.fs.attacking {
            flags.push("attacking".into());
        }
        if ob.fs.blocked {
            flags.push("blocked".into());
        }
        if ob.fs.blocking.is_some() {
            flags.push("blocking".into());
        }
        if ob.fs.doomed {
            flags.push("doomed".into());
        }
        for i in &ob.fs.once_used {
            flags.push(format!("once{i}"));
        }
        if self.is_settling(o) {
            flags.push("settling".into());
        }
        if ob.fs.tenacity_used {
            flags.push("tenacity-used".into());
        }
        if ob.fs.ward > 0 {
            flags.push(format!("ward{}", ob.fs.ward));
        }
        flags.sort();
        let flags = if flags.is_empty() { "-".to_string() } else { flags.join(",") };
        let kws = ob.cur.kw.render();
        let kws = if kws.is_empty() { "-".to_string() } else { kws.join(",") };
        format!(
            "field {} #{} {} {} w{} c{} {} {} kw {}",
            p.name(),
            o,
            ob.card.id,
            body,
            ob.fs.wounds,
            ob.fs.counters,
            if ob.fs.exhausted { "exhausted" } else { "ready" },
            flags,
            kws
        )
    }

    fn objs_list(&self, v: &[Oid]) -> String {
        let live: Vec<String> =
            v.iter().filter(|&&o| self.on_field(o)).map(|o| format!("#{o}")).collect();
        if live.is_empty() {
            "-".to_string()
        } else {
            live.join(",")
        }
    }

    fn effect_lines(&mut self) {
        let mut aura_i = 0;
        for r in self.records.clone() {
            let (who, dur, desc, objs) = match &r.kind {
                RecKind::Aura { .. } => {
                    let ev = self.aura_evals[aura_i].clone();
                    aura_i += 1;
                    let Some(leaf) = ev.leaves.first() else { continue };
                    let (desc, is_cheaper) = match &leaf.kind {
                        LeafKind::Modify(e, c) => (format!("modify {e} {c}"), false),
                        LeafKind::Setbody(e, c) => (format!("setbody {e} {c}"), false),
                        LeafKind::Swap => ("swapstats".to_string(), false),
                        LeafKind::Grant(k) => (format!("grant {}", k.render()), false),
                        LeafKind::Cheaper(n, _) => (format!("cheaper {n}"), true),
                    };
                    let objs = if is_cheaper || !leaf.active {
                        "-".to_string()
                    } else {
                        self.objs_list(&leaf.affected)
                    };
                    (ev.ctrl, "aura", desc, objs)
                }
                kind => {
                    let desc = match kind {
                        RecKind::Modify(e, c) => format!("modify {e} {c}"),
                        RecKind::Setbody(e, c) => format!("setbody {e} {c}"),
                        RecKind::Swap => "swapstats".to_string(),
                        RecKind::Grant(k) => format!("grant {}", k.render()),
                        RecKind::Strip => "strip".to_string(),
                        RecKind::Control => format!("control {}", r.ctrl.name()),
                        RecKind::Aura { .. } => unreachable!(),
                    };
                    (r.ctrl, "turn", desc, self.objs_list(&r.affected))
                }
            };
            self.raw(format!("effect {} ts{} {} {} {} on {}", r.eid, r.ts, who.name(), dur, desc, objs));
        }
    }

    /// Print the `VAULT` block.
    pub(crate) fn vault_block(&mut self) {
        self.raw("VAULT BEGIN");
        for p in Player::BOTH {
            for (i, &o) in self.players[p.idx()].vault.clone().iter().enumerate() {
                let line = format!("vault {} {} #{} {}", p.name(), i + 1, o, self.obj(o).card.id);
                self.raw(line);
            }
        }
        self.raw("VAULT END");
    }

    /// Print the `CARD` block for `id`.
    pub(crate) fn card_block(&mut self, id: &str) {
        self.raw(format!("CARD BEGIN {id}"));
        match self.db.get(id).cloned() {
            None => self.raw("unknown"),
            Some(c) => {
                self.raw(format!("name {}", c.name));
                self.raw(format!("type {}", c.ctype.name()));
                self.raw(format!("cost {}", c.cost));
                if c.ctype == CardType::Unit {
                    self.raw(format!("body {}/{}", c.edge, c.core));
                }
                let tags = if c.tags.is_empty() { "-".to_string() } else { c.tags.join(",") };
                self.raw(format!("tags {tags}"));
                let mut kws: Vec<String> = c.keywords.iter().map(KwSpec::render).collect();
                kws.sort();
                let kws = if kws.is_empty() { "-".to_string() } else { kws.join(",") };
                self.raw(format!("keywords {kws}"));
                for (i, ab) in c.abilities.iter().enumerate() {
                    self.raw(format!("ability {} {}", i + 1, ab.rendered));
                }
            }
        }
        self.raw("CARD END");
    }
}
