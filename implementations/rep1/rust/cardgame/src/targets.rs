//! Target legality and candidate enumeration (SPEC.md section 12).

use crate::model::*;
use crate::state::*;

impl Engine {
    /// Whether object `o` is a legal unit/relic-style target: on the Field,
    /// of the wanted type, matching the filters, and not protected by the
    /// spectral rule (units only).
    fn field_target_ok(
        &self,
        o: Oid,
        ctype: CardType,
        filters: &[Filter],
        ctrl: Player,
        src: Oid,
    ) -> bool {
        let ob = self.obj(o);
        if ob.zone != Zone::Field || ob.card.ctype != ctype {
            return false;
        }
        if ctype == CardType::Unit && ob.cur.kw.has(Keyword::Spectral) && ob.cur.ctrl != ctrl {
            return false;
        }
        self.filters_ok(o, filters, ctrl, src)
    }

    /// Whether `t` is a legal target for `spec` (SPEC.md 12.1–12.3).
    ///
    /// `exclude` is the Chain entry being announced or resolved (0 for none).
    pub(crate) fn target_legal(
        &mut self,
        spec: &TSpec,
        t: Tgt,
        ctrl: Player,
        src: Oid,
        exclude: Cid,
    ) -> bool {
        self.ensure();
        match (spec, t) {
            (TSpec::Unit(f), Tgt::Obj(o)) => {
                self.exists(o) && self.field_target_ok(o, CardType::Unit, f, ctrl, src)
            }
            (TSpec::Relic(f), Tgt::Obj(o)) => {
                self.exists(o) && self.field_target_ok(o, CardType::Relic, f, ctrl, src)
            }
            (TSpec::Any(_), Tgt::Player(_)) | (TSpec::Player, Tgt::Player(_)) => true,
            (TSpec::Any(f), Tgt::Obj(o)) => {
                self.exists(o) && self.field_target_ok(o, CardType::Unit, f, ctrl, src)
            }
            (TSpec::Chained, Tgt::Entry(c)) => c != exclude && self.chain.iter().any(|e| e.cid == c),
            (TSpec::AshCard(f), Tgt::Obj(o)) => {
                self.exists(o)
                    && self.obj(o).zone == Zone::Ash
                    && self.filters_ok(o, f, ctrl, src)
            }
            _ => false,
        }
    }

    /// All legal targets for `spec`, in ascending target-key order.
    pub(crate) fn candidates(&mut self, spec: &TSpec, ctrl: Player, src: Oid, exclude: Cid) -> Vec<Tgt> {
        self.ensure();
        let mut out = Vec::new();
        match spec {
            TSpec::Player => out.extend(Player::BOTH.map(Tgt::Player)),
            TSpec::Any(f) => {
                out.extend(Player::BOTH.map(Tgt::Player));
                for &o in &self.field {
                    if self.field_target_ok(o, CardType::Unit, f, ctrl, src) {
                        out.push(Tgt::Obj(o));
                    }
                }
            }
            TSpec::Unit(f) => {
                for &o in &self.field {
                    if self.field_target_ok(o, CardType::Unit, f, ctrl, src) {
                        out.push(Tgt::Obj(o));
                    }
                }
            }
            TSpec::Relic(f) => {
                for &o in &self.field {
                    if self.field_target_ok(o, CardType::Relic, f, ctrl, src) {
                        out.push(Tgt::Obj(o));
                    }
                }
            }
            TSpec::Chained => {
                let mut cids: Vec<Cid> =
                    self.chain.iter().map(|e| e.cid).filter(|&c| c != exclude).collect();
                cids.sort_unstable();
                out.extend(cids.into_iter().map(Tgt::Entry));
            }
            TSpec::AshCard(f) => {
                let mut v: Vec<Oid> = Vec::new();
                for p in Player::BOTH {
                    for &o in &self.players[p.idx()].ash {
                        if self.filters_ok(o, f, ctrl, src) {
                            v.push(o);
                        }
                    }
                }
                self.sort_canonical(&mut v);
                out.extend(v.into_iter().map(Tgt::Obj));
            }
        }
        out
    }

    /// All distinct target tuples for `specs`, in ascending lexicographic order.
    pub(crate) fn target_tuples(
        &mut self,
        specs: &[TSpec],
        ctrl: Player,
        src: Oid,
    ) -> Vec<Vec<Tgt>> {
        let lists: Vec<Vec<Tgt>> = specs.iter().map(|s| self.candidates(s, ctrl, src, 0)).collect();
        let mut out = Vec::new();
        let mut cur = Vec::new();
        fn rec(lists: &[Vec<Tgt>], cur: &mut Vec<Tgt>, out: &mut Vec<Vec<Tgt>>) {
            if cur.len() == lists.len() {
                out.push(cur.clone());
                return;
            }
            for &t in &lists[cur.len()] {
                if cur.contains(&t) {
                    continue;
                }
                cur.push(t);
                rec(lists, cur, out);
                cur.pop();
            }
        }
        rec(&lists, &mut cur, &mut out);
        out
    }
}
