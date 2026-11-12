//! Match setup and command execution (SPEC.md sections 8, 10 and 24).

use std::collections::VecDeque;
use std::fmt;
use std::rc::Rc;

use crate::database::Database;
use crate::matchfile::{Action, Command, Setup, SetupZone, Trace};
use crate::model::*;
use crate::rng::Rng;
use crate::state::*;

/// A fatal setup problem found while building the engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    /// A setup zone line names a card the database does not define.
    UnknownCard(String),
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EngineError::UnknownCard(id) => write!(f, "unknown card {id}"),
        }
    }
}

impl std::error::Error for EngineError {}

impl Engine {
    /// Build a match from a parsed setup block and a validated database, and
    /// run it forward to its first decision point (SPEC.md section 8). The
    /// setup events are available from [`Engine::take_output`].
    pub fn new(setup: &Setup, db: Rc<Database>) -> Result<Engine, EngineError> {
        for p in 0..2 {
            for z in &setup.zones[p] {
                for id in z {
                    if db.get(id).is_none() {
                        return Err(EngineError::UnknownCard(id.clone()));
                    }
                }
            }
        }
        let mut e = Engine {
            db: db.clone(),
            cfg: Config {
                maxcap: setup.maxcap,
                handmax: setup.handmax,
                turnlimit: setup.turnlimit,
                trace: setup.trace,
            },
            objs: Vec::new(),
            players: [
                PlayerState::new(setup.spire, setup.cap[0]),
                PlayerState::new(setup.spire, setup.cap[1]),
            ],
            field: Vec::new(),
            chain: Vec::new(),
            records: Vec::new(),
            delayed: Vec::new(),
            pending: Vec::new(),
            next_ts: 1,
            next_cid: 1,
            next_eid: 1,
            turn: 1,
            active: setup.first,
            step: Step::Dawn,
            rng: Rng::new(setup.seed),
            out: String::new(),
            seq: 0,
            result: None,
            cont: Cont::Waiting,
            decision: None,
            round_step: Step::Main1,
            passes: 0,
            holder: setup.first,
            dirty: true,
            aura_evals: Vec::new(),
            in_derive: false,
            riposte_dealt: Vec::new(),
            triggers_on: false,
        };
        e.emit(format!("GAME-START {}", setup.first.name()));

        // Step 5: oids, zone by zone, player A first.
        let mut field_objs: Vec<(Oid, Player)> = Vec::new();
        for p in Player::BOTH {
            for (zi, ids) in setup.zones[p.idx()].iter().enumerate() {
                for id in ids {
                    let card = db.get(id).expect("checked above").clone();
                    let o = e.new_object(card, p);
                    match zi {
                        z if z == SetupZone::Deck as usize => {
                            e.players[p.idx()].vault.push_back(o);
                            e.obj_mut(o).zone = Zone::Vault;
                        }
                        z if z == SetupZone::Hand as usize => e.push_hand(o),
                        z if z == SetupZone::Field as usize => field_objs.push((o, p)),
                        z if z == SetupZone::Ash as usize => e.push_ash(o),
                        _ => e.push_rift(o),
                    }
                }
            }
        }
        // Step 6: the Field, in ascending oid order, firing nothing.
        for (o, p) in field_objs {
            e.enter_field(o, p, true);
        }
        // Step 7: shuffle.
        if setup.shuffle {
            for p in Player::BOTH {
                let mut v: Vec<Oid> = e.players[p.idx()].vault.drain(..).collect();
                e.rng.shuffle(&mut v);
                e.players[p.idx()].vault = VecDeque::from(v);
                e.emit(format!("SHUFFLE {}", p.name()));
            }
        }
        // Step 8: opening hands, firing no triggers.
        for p in [setup.first, setup.first.other()] {
            for _ in 0..setup.opening {
                if !e.draw_one(p) {
                    break;
                }
            }
        }
        // Step 9: settle once.
        e.triggers_on = true;
        e.touch();
        e.settle();
        if e.result.is_none() {
            e.cont = Cont::TurnStart;
        }
        e.run();
        Ok(e)
    }

    /// Emit an `ERR` line for a rejected script line.
    pub fn syntax_error(&mut self, line: usize) {
        self.raw(format!("ERR {line} bad-syntax"));
    }

    /// Execute one well-formed script command found on script line `line`
    /// (1-based, counting every line of the match file).
    pub fn execute(&mut self, line: usize, cmd: Command) {
        match cmd {
            Command::Dump => self.dump_block(),
            Command::Legal => self.legal_block(),
            Command::Vault => self.vault_block(),
            Command::Card(id) => self.card_block(&id),
            Command::Action(p, a) => {
                if self.execute_action(line, p, a) {
                    match self.cfg.trace {
                        Trace::None => {}
                        Trace::Legal => self.legal_block(),
                        Trace::State => self.dump_block(),
                    }
                }
            }
        }
    }

    /// Finish the run: emit `RESULT pending none` if the match is still going.
    pub fn finish(&mut self) {
        if self.result.is_none() {
            self.emit("RESULT pending none");
        }
    }

    fn reject(&mut self, line: usize, kind: &str) -> bool {
        self.raw(format!("ERR {line} {kind}"));
        false
    }

    /// Process an action; returns whether it was accepted.
    fn execute_action(&mut self, line: usize, p: Player, action: Action) -> bool {
        if self.result.is_some() {
            return self.reject(line, "game-over");
        }
        let (waiting, decision) = self.decision.expect("running match has a decision");
        if p != waiting {
            return self.reject(line, "not-your-turn");
        }
        let right_decision = matches!(
            (&action, decision),
            (Action::Concede, _)
                | (Action::Pass | Action::Play { .. } | Action::Act { .. }, Decision::Priority)
                | (Action::Attack(_), Decision::Attackers)
                | (Action::Block(_), Decision::Blockers)
        );
        if !right_decision {
            return self.reject(line, "wrong-decision");
        }
        let outcome = match action {
            Action::Concede => {
                let ps = &mut self.players[p.idx()];
                if ps.lost.is_none() {
                    ps.lost = Some(Reason::Concede);
                }
                self.end_match();
                Ok(())
            }
            Action::Pass => {
                self.act_pass(p);
                Ok(())
            }
            Action::Play { pos, targets } => self.do_play(p, pos, &targets).map(|()| {
                self.after_priority_action(p);
            }),
            Action::Act { oid, index, targets } => {
                self.do_act(p, oid, index, &targets).map(|()| {
                    self.after_priority_action(p);
                })
            }
            Action::Attack(oids) => self.do_attack(&oids),
            Action::Block(pairs) => self.do_block(&pairs),
        };
        match outcome {
            Err(kind) => self.reject(line, kind),
            Ok(()) => {
                self.run();
                true
            }
        }
    }
}
