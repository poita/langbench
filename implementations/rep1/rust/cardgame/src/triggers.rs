//! Trigger collection and pushing (SPEC.md section 13).

use std::rc::Rc;

use crate::model::*;
use crate::state::*;

impl Engine {
    /// Collect every `on <ev>` ability of `o`, controlled by `ctrl`.
    ///
    /// Does not check whether `o` is on the Field or stripped; callers do.
    pub(crate) fn collect_from(&mut self, o: Oid, ctrl: Player, ev: Event, subject: Subject) {
        let ob = self.obj(o);
        if !ob.card.listens(ev) {
            return;
        }
        let ts = ob.ts;
        let card = ob.card.clone();
        for (i, ab) in card.abilities.iter().enumerate() {
            if ab.kind == AbilityKind::On && ab.event == Some(ev) {
                self.pending.push(Pending { ctrl, src: o, idx: i + 1, ts, subject, delayed: None });
            }
        }
    }

    /// Whether a Field object is currently listening (on the Field, not stripped).
    fn listening(&self, o: Oid) -> bool {
        let ob = self.obj(o);
        ob.zone == Zone::Field && !ob.cur.stripped
    }

    /// Collect `ev` from the object itself if it is a listening Field object.
    pub(crate) fn collect_self(&mut self, o: Oid, ev: Event, subject: Subject) {
        self.ensure();
        if self.listening(o) {
            let ctrl = self.obj(o).cur.ctrl;
            self.collect_from(o, ctrl, ev, subject);
        }
    }

    /// Collect `ally` from listeners controlled by `x_ctrl` and `enemy` from
    /// the others, for an event about the unit `x` (arrive/dies).
    pub(crate) fn collect_relative(
        &mut self,
        ally: Event,
        enemy: Event,
        x: Oid,
        x_ctrl: Player,
        subject: Subject,
    ) {
        self.ensure();
        for i in 0..self.field.len() {
            let y = self.field[i];
            if y == x || !self.listening(y) {
                continue;
            }
            let c = self.obj(y).cur.ctrl;
            let ev = if c == x_ctrl { ally } else { enemy };
            self.collect_from(y, c, ev, subject);
        }
    }

    /// Collect `own` from Field objects controlled by `p` and `enemy` from the
    /// opponent's, for an event about player `p`.
    pub(crate) fn collect_player(
        &mut self,
        own: Option<Event>,
        enemy: Option<Event>,
        p: Player,
        subject: Subject,
    ) {
        self.ensure();
        for i in 0..self.field.len() {
            let y = self.field[i];
            if !self.listening(y) {
                continue;
            }
            let c = self.obj(y).cur.ctrl;
            let ev = if c == p { own } else { enemy };
            if let Some(ev) = ev {
                self.collect_from(y, c, ev, subject);
            }
        }
    }

    /// Collect `all` from every listening Field object, and `mine` from those
    /// controlled by the active player (turn-start/turn-end events).
    pub(crate) fn collect_turn_event(&mut self, all: Event, mine: Event) {
        self.ensure();
        let subject = Subject::Player(self.active);
        for i in 0..self.field.len() {
            let y = self.field[i];
            if !self.listening(y) {
                continue;
            }
            let c = self.obj(y).cur.ctrl;
            self.collect_from(y, c, all, subject);
            if c == self.active {
                self.collect_from(y, c, mine, subject);
            }
        }
    }

    /// Fire every delayed trigger of this timing for which `pick` holds.
    pub(crate) fn fire_delayed(&mut self, when: When) {
        let active = self.active;
        let mut keep = Vec::new();
        let list = std::mem::take(&mut self.delayed);
        for d in list {
            let fires = d.when == when && (when != When::YourNextTurnStart || d.ctrl == active);
            if fires {
                self.pending.push(Pending {
                    ctrl: d.ctrl,
                    src: d.src,
                    idx: 0,
                    ts: d.ts,
                    subject: Subject::None,
                    delayed: Some(d),
                });
            } else {
                keep.push(d);
            }
        }
        self.delayed = keep;
    }

    /// Push the pending batch onto the Chain (SPEC.md 13.3). Reports whether
    /// the pending list was non-empty.
    pub(crate) fn push_triggers(&mut self) -> bool {
        if self.pending.is_empty() {
            return false;
        }
        self.ensure();
        let mut batch = std::mem::take(&mut self.pending);
        let active = self.active;
        batch.sort_by_key(|p| (u8::from(p.ctrl != active), p.ts, p.src, p.idx));
        let mut entries: Vec<Entry> = Vec::new();
        for p in batch {
            let (specs, targets): (Rc<Vec<TSpec>>, Vec<Tgt>) = match &p.delayed {
                Some(d) => (d.specs.clone(), d.targets.clone()),
                None => {
                    let card = self.obj(p.src).card.clone();
                    let specs = card.abilities[p.idx - 1].targets.clone();
                    let mut chosen: Vec<Tgt> = Vec::new();
                    let mut ok = true;
                    for spec in specs.iter() {
                        match self.candidates(spec, p.ctrl, p.src, 0).into_iter().find(|t| !chosen.contains(t)) {
                            Some(t) => chosen.push(t),
                            None => {
                                ok = false;
                                break;
                            }
                        }
                    }
                    if !ok {
                        self.emit(format!("TRIGGER-NO-TARGET {} #{} {}", p.ctrl.name(), p.src, p.idx));
                        continue;
                    }
                    (specs, chosen)
                }
            };
            let cid = self.next_cid;
            self.next_cid += 1;
            let mut line = format!("TRIGGER {} ~{} #{} {}", p.ctrl.name(), cid, p.src, p.idx);
            for t in &targets {
                line.push(' ');
                line.push_str(&self.render_tgt(*t));
            }
            self.emit(line);
            entries.push(Entry {
                cid,
                kind: EntryKind::Trigger,
                ctrl: p.ctrl,
                src: p.src,
                idx: p.idx,
                targets: targets.into_iter().map(|tgt| TSlot { tgt, removed: false }).collect(),
                specs,
                subject: p.subject,
                delayed: p.delayed,
            });
        }
        for e in entries.into_iter().rev() {
            self.chain.push(e);
        }
        true
    }
}
