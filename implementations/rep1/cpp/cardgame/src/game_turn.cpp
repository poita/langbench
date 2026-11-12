// Turn structure, priority, combat and the action entry point
// (SPEC.md sections 9, 10, 19, 20, 24).
#include <algorithm>
#include <ostream>

#include "spiremark/game.hpp"

namespace spiremark {

using detail::C;
using detail::O;
using detail::P;
using detail::S;

const char* Game::step_name(Step s) const {
    switch (s) {
        case Step::Dawn: return "dawn";
        case Step::Draw: return "draw";
        case Step::Main1: return "main1";
        case Step::ClashAttack: return "clash-attack";
        case Step::ClashBlock: return "clash-block";
        case Step::ClashRiposte: return "clash-riposte";
        case Step::ClashDamage: return "clash-damage";
        case Step::ClashEnd: return "clash-end";
        case Step::Main2: return "main2";
        case Step::DuskTrigger: return "dusk-trigger";
        case Step::DuskDiscard: return "dusk-discard";
        case Step::DuskCleanup: return "dusk-cleanup";
    }
    return "";
}

// ------------------------------------------------------------------ the loop --

void Game::run() {
    while (!over_ && decision_.kind == DecisionKind::None) enter(next_step_);
}

void Game::start_round() {
    pass_count_ = 0;
    settle();
    if (over_) return;
    holder_ = active_;
    decision_ = {DecisionKind::Priority, holder_};
}

void Game::finish_round() {
    switch (cur_step_) {
        case Step::Main1: next_step_ = Step::ClashAttack; break;
        case Step::ClashAttack: next_step_ = Step::ClashBlock; break;
        case Step::ClashBlock:
            next_step_ = any_riposte_in_combat() ? Step::ClashRiposte : Step::ClashDamage;
            break;
        case Step::ClashRiposte: next_step_ = Step::ClashDamage; break;
        case Step::ClashDamage: next_step_ = Step::ClashEnd; break;
        case Step::ClashEnd:
            for (int oid : field_) {
                Obj& o = obj(oid);
                o.attacking = o.blocking = o.blocked = false;
                o.blocking_oid = 0;
                o.blockers.clear();
            }
            riposted_.clear();
            touch();
            next_step_ = Step::Main2;
            break;
        case Step::Main2: next_step_ = Step::DuskTrigger; break;
        case Step::DuskTrigger: next_step_ = Step::DuskDiscard; break;
        default: break;
    }
}

void Game::enter(Step s) {
    cur_step_ = s;
    ensure_derived();
    switch (s) {
        case Step::Dawn:
            emit("TURN", turn_, P{active_});
            emit("PHASE", "dawn");
            do_dawn();
            drain();
            next_step_ = Step::Draw;
            break;
        case Step::Draw:
            emit("PHASE", "draw");
            if (turn_ != 1) draw_cards(active_, 1);
            drain();
            next_step_ = Step::Main1;
            break;
        case Step::Main1:
            emit("PHASE", "main1");
            start_round();
            break;
        case Step::ClashAttack:
            emit("PHASE", "clash-attack");
            settle();
            if (over_) return;
            decision_ = {DecisionKind::Attackers, active_};
            break;
        case Step::ClashBlock:
            emit("PHASE", "clash-block");
            riposted_.clear();
            settle();
            if (over_) return;
            decision_ = {DecisionKind::Blockers, opponent(active_)};
            break;
        case Step::ClashRiposte:
            emit("PHASE", "clash-riposte");
            deal_combat(true);
            start_round();
            break;
        case Step::ClashDamage:
            emit("PHASE", "clash-damage");
            deal_combat(false);
            start_round();
            break;
        case Step::ClashEnd: {
            emit("PHASE", "clash-end");
            std::vector<int> inc;
            for (int oid : field_)
                if (in_combat(obj(oid))) inc.push_back(oid);
            for (int oid : inc)
                collect_self(Event::EndOfCombat, oid, Ref::object(static_cast<std::uint64_t>(oid)), false, 0);
            for (auto it = delayed_.begin(); it != delayed_.end();) {
                if (it->when != When::EndOfCombat) { ++it; continue; }
                Pending p;
                p.controller = it->controller;
                p.ts = it->ts;
                p.oid = it->source;
                p.source = it->source;
                p.index = 0;
                p.effects = it->effects;
                p.specs = it->specs;
                p.targets = it->targets;
                pending_.push_back(std::move(p));
                it = delayed_.erase(it);
            }
            start_round();
            break;
        }
        case Step::Main2:
            emit("PHASE", "main2");
            start_round();
            break;
        case Step::DuskTrigger: {
            emit("PHASE", "dusk-trigger");
            Ref it = Ref::player(active_);
            collect_all(Event::TurnEnd, 0, false, it);
            collect_all(Event::YourTurnEnd, active_, true, it);
            for (auto d = delayed_.begin(); d != delayed_.end();) {
                if (d->when != When::TurnEnd) { ++d; continue; }
                Pending p;
                p.controller = d->controller;
                p.ts = d->ts;
                p.oid = d->source;
                p.source = d->source;
                p.index = 0;
                p.effects = d->effects;
                p.specs = d->specs;
                p.targets = d->targets;
                pending_.push_back(std::move(p));
                d = delayed_.erase(d);
            }
            start_round();
            break;
        }
        case Step::DuskDiscard:
            emit("PHASE", "dusk-discard");
            while (static_cast<int>(hand_[active_].size()) > cfg_.handmax) discard_one(active_);
            drain();
            next_step_ = Step::DuskCleanup;
            break;
        case Step::DuskCleanup:
            emit("PHASE", "dusk-cleanup");
            do_cleanup();
            drain();
            if (over_) return;
            ++turn_;
            active_ = opponent(active_);
            if (turn_ > cfg_.turnlimit) {
                end_with_draw("turn-limit");
                return;
            }
            next_step_ = Step::Dawn;
            break;
    }
}

void Game::do_dawn() {
    cap_[active_] = std::min<std::int64_t>(cap_[active_] + 1, cfg_.maxcap);
    for (int p = 0; p < 2; ++p) {
        ember_[p] = cap_[p];
        emit("EMBER", P{p}, ember_[p], cap_[p]);
    }
    touch();
    std::vector<int> snapshot = field_;
    ensure_derived();
    for (int oid : snapshot)
        if (obj(oid).ctrl == active_ && obj(oid).exhausted) set_exhausted(oid, false);
    for (int oid : field_) {
        obj(oid).tenacity_used = false;
        obj(oid).once.clear();
    }
    Ref it = Ref::player(active_);
    collect_all(Event::TurnStart, 0, false, it);
    collect_all(Event::YourTurnStart, active_, true, it);
    for (auto d = delayed_.begin(); d != delayed_.end();) {
        if (d->when != When::YourNextTurnStart || d->controller != active_) { ++d; continue; }
        Pending p;
        p.controller = d->controller;
        p.ts = d->ts;
        p.oid = d->source;
        p.source = d->source;
        p.index = 0;
        p.effects = d->effects;
        p.specs = d->specs;
        p.targets = d->targets;
        pending_.push_back(std::move(p));
        d = delayed_.erase(d);
    }
}

void Game::do_cleanup() {
    for (int oid : field_) {
        Obj& o = obj(oid);
        o.wounds = 0;
        o.doomed = false;
        o.ward = 0;
    }
    shield_[0] = shield_[1] = 0;
    for (const Record& r : records_) {
        if (r.aura || r.kind != RecKind::Control) continue;
        for (int oid : r.affected)
            if (on_field(oid)) obj(oid).since = turn_;
    }
    records_.erase(std::remove_if(records_.begin(), records_.end(),
                                  [](const Record& r) { return !r.aura; }),
                   records_.end());
    delayed_.erase(std::remove_if(delayed_.begin(), delayed_.end(),
                                  [](const Delayed& d) {
                                      return d.when == When::TurnEnd || d.when == When::EndOfCombat;
                                  }),
                   delayed_.end());
    touch();
}

// ------------------------------------------------------------------- actions --

std::optional<ErrKind> Game::apply(const Action& a) {
    if (over_) return ErrKind::GameOver;
    if (a.player != decision_.player) return ErrKind::NotYourTurn;
    switch (a.type) {
        case ActionType::Pass:
        case ActionType::Play:
        case ActionType::Act:
            if (decision_.kind != DecisionKind::Priority) return ErrKind::WrongDecision;
            break;
        case ActionType::Attack:
            if (decision_.kind != DecisionKind::Attackers) return ErrKind::WrongDecision;
            break;
        case ActionType::Block:
            if (decision_.kind != DecisionKind::Blockers) return ErrKind::WrongDecision;
            break;
        case ActionType::Concede: break;
    }
    switch (a.type) {
        case ActionType::Concede:
            if (loss_reason_[a.player].empty()) loss_reason_[a.player] = "concede";
            check_losses();
            return std::nullopt;
        case ActionType::Pass:
            apply_pass();
            break;
        case ActionType::Play: {
            auto err = do_play(a);
            if (err) return err;
            after_player_action(a.player);
            break;
        }
        case ActionType::Act: {
            auto err = do_act(a);
            if (err) return err;
            after_player_action(a.player);
            break;
        }
        case ActionType::Attack: {
            auto err = do_attack(a);
            if (err) return err;
            break;
        }
        case ActionType::Block: {
            auto err = do_block(a);
            if (err) return err;
            break;
        }
    }
    run();
    return std::nullopt;
}

void Game::after_player_action(int actor) {
    pass_count_ = 0;
    holder_ = actor;
    bool acted = settle();
    if (over_) return;
    if (acted) {
        pass_count_ = 0;
        holder_ = active_;
    }
    decision_.player = holder_;
}

void Game::apply_pass() {
    emit("PASS", P{holder_});
    ++pass_count_;
    if (pass_count_ == 1) {
        holder_ = opponent(holder_);
        decision_.player = holder_;
        return;
    }
    if (!chain_.empty()) {
        pass_count_ = 0;
        resolve_top();
        settle();
        if (over_) return;
        holder_ = active_;
        decision_.player = holder_;
        return;
    }
    decision_ = Decision{};
    finish_round();
}

// -------------------------------------------------------------------- combat --

bool Game::can_attack(int oid) {
    ensure_derived();
    const Obj& o = obj(oid);
    if (o.zone != Zone::Field || o.ctrl != active_ || o.card->type != CardType::Unit) return false;
    if (o.exhausted) return false;
    if (is_settling(o) && !has_kw(oid, Kw::Vanguard)) return false;
    if (has_kw(oid, Kw::Shackled)) return false;
    return true;
}

bool Game::can_block(int b, int a) {
    ensure_derived();
    const Obj& ob = obj(b);
    if (ob.zone != Zone::Field || ob.ctrl != opponent(active_) || ob.card->type != CardType::Unit)
        return false;
    if (ob.exhausted || has_kw(b, Kw::Siegework)) return false;
    const Obj& oa = obj(a);
    if (oa.zone != Zone::Field || !oa.attacking) return false;
    if (has_kw(a, Kw::Ghostwalk) && !has_kw(b, Kw::Ghostwalk) && !has_kw(b, Kw::Skyhook)) return false;
    return true;
}

bool Game::any_riposte_in_combat() {
    ensure_derived();
    for (int oid : field_)
        if (in_combat(obj(oid)) && has_kw(oid, Kw::Riposte)) return true;
    return false;
}

std::optional<ErrKind> Game::do_attack(const Action& a) {
    std::vector<std::uint64_t> list = a.attackers;
    std::vector<std::uint64_t> sorted = list;
    std::sort(sorted.begin(), sorted.end());
    for (std::size_t i = 1; i < sorted.size(); ++i)
        if (sorted[i] == sorted[i - 1]) return ErrKind::DuplicateAttacker;
    for (std::uint64_t id : sorted)
        if (!valid_oid(id) || !can_attack(static_cast<int>(id))) return ErrKind::IllegalAttacker;
    for (int oid : field_) {
        if (!can_attack(oid) || !has_kw(oid, Kw::Relentless)) continue;
        if (!std::binary_search(sorted.begin(), sorted.end(), static_cast<std::uint64_t>(oid)))
            return ErrKind::MissingRequiredAttacker;
    }
    decision_ = Decision{};
    if (sorted.empty()) {
        next_step_ = Step::Main2;
        return std::nullopt;
    }
    std::vector<int> atk;
    for (std::uint64_t id : sorted) atk.push_back(static_cast<int>(id));
    declare_attackers(atk);
    return std::nullopt;
}

void Game::declare_attackers(std::vector<int> atk) {
    for (int oid : atk) {
        Obj& o = obj(oid);
        o.attacking = true;
        touch();
        if (!has_kw(oid, Kw::Vigil)) set_exhausted(oid, true);
        emit("ATTACK", O{oid});
    }
    for (int oid : atk)
        collect_self(Event::Attacks, oid, Ref::object(static_cast<std::uint64_t>(oid)), false, 0);
    start_round();
}

std::optional<ErrKind> Game::do_block(const Action& a) {
    std::vector<std::pair<std::uint64_t, std::uint64_t>> pairs = a.blocks;
    std::sort(pairs.begin(), pairs.end());
    for (std::size_t i = 1; i < pairs.size(); ++i)
        if (pairs[i].first == pairs[i - 1].first) return ErrKind::DuplicateBlocker;
    for (auto& pr : pairs) {
        if (!valid_oid(pr.first) || !valid_oid(pr.second) ||
            !can_block(static_cast<int>(pr.first), static_cast<int>(pr.second)))
            return ErrKind::IllegalBlocker;
    }
    // Provoke (19.4).
    int defender = opponent(active_);
    for (int aoid : field_) {
        const Obj& at = obj(aoid);
        if (!at.attacking || !has_kw(aoid, Kw::Provoke) || !at.blockers.empty()) continue;
        bool covered = false;
        for (auto& pr : pairs)
            if (pr.second == static_cast<std::uint64_t>(aoid)) covered = true;
        if (covered) continue;
        for (int boid : field_) {
            const Obj& b = obj(boid);
            if (b.ctrl != defender || b.card->type != CardType::Unit) continue;
            bool used = false;
            for (auto& pr : pairs)
                if (pr.first == static_cast<std::uint64_t>(boid)) used = true;
            if (used) continue;
            if (can_block(boid, aoid)) return ErrKind::MissingRequiredBlock;
        }
    }
    decision_ = Decision{};
    std::vector<std::pair<int, int>> ps;
    for (auto& pr : pairs) ps.emplace_back(static_cast<int>(pr.first), static_cast<int>(pr.second));
    declare_blockers(ps);
    return std::nullopt;
}

void Game::declare_blockers(std::vector<std::pair<int, int>> pairs) {
    std::vector<int> blockers;
    for (auto& pr : pairs) {
        Obj& b = obj(pr.first);
        Obj& a = obj(pr.second);
        b.blocking = true;
        b.blocking_oid = pr.second;
        a.blockers.push_back(pr.first);
        a.blocked = true;
        emit("BLOCK", O{pr.first}, O{pr.second});
        blockers.push_back(pr.first);
    }
    touch();
    std::vector<int> attackers;
    for (int oid : field_)
        if (obj(oid).attacking) attackers.push_back(oid);
    for (int oid : attackers) sort_canonical(obj(oid).blockers);
    std::vector<int> unblocked;
    for (int oid : attackers)
        if (obj(oid).blockers.empty()) unblocked.push_back(oid);
    std::sort(unblocked.begin(), unblocked.end());
    for (int oid : unblocked) emit("UNBLOCKED", O{oid});
    for (auto& pr : pairs)
        collect_self(Event::Blocks, pr.first, Ref::object(static_cast<std::uint64_t>(pr.second)), false, 0);
    for (int oid : attackers) {
        const Obj& a = obj(oid);
        if (!a.blockers.empty())
            collect_self(Event::Blocked, oid, Ref::object(static_cast<std::uint64_t>(a.blockers[0])), false, 0);
    }
    for (int oid : unblocked)
        collect_self(Event::Unblocked, oid, Ref::object(static_cast<std::uint64_t>(oid)), false, 0);
    start_round();
}

namespace {
struct Assign {
    int src;
    Ref dst;
    std::int64_t amount;
};
}  // namespace

void Game::deal_combat(bool riposte_step) {
    ensure_derived();
    std::vector<int> dealers;
    for (int oid : field_) {
        const Obj& o = obj(oid);
        if (!in_combat(o)) continue;
        if (riposte_step) {
            if (has_kw(oid, Kw::Riposte)) dealers.push_back(oid);
        } else if (!riposted_.count(oid)) {
            dealers.push_back(oid);
        }
    }
    if (riposte_step) riposted_.insert(dealers.begin(), dealers.end());

    std::vector<Assign> assigns;
    int defending = opponent(active_);
    for (int u : dealers) {
        const Obj& o = obj(u);
        std::int64_t e = cur_edge(u);
        if (e <= 0) continue;
        if (o.blocking) {
            if (o.blocking_oid && on_field(o.blocking_oid))
                assigns.push_back({u, Ref::object(static_cast<std::uint64_t>(o.blocking_oid)), e});
        } else if (o.attacking) {
            if (!o.blocked) {
                assigns.push_back({u, Ref::player(defending), e});
                continue;
            }
            std::vector<int> list;
            for (int b : o.blockers)
                if (on_field(b) && obj(b).blocking && obj(b).blocking_oid == u) list.push_back(b);
            sort_canonical(list);
            if (list.empty()) continue;
            std::int64_t r = e;
            bool venom = has_kw(u, Kw::Venom);
            std::vector<std::int64_t> give(list.size(), 0);
            for (std::size_t i = 0; i < list.size(); ++i) {
                std::int64_t need = venom ? 1 : std::max<std::int64_t>(0, cur_core(list[i]) - obj(list[i]).wounds);
                std::int64_t g = std::min(r, need);
                give[i] = g;
                r -= g;
            }
            if (r > 0) {
                if (has_kw(u, Kw::Pierce)) assigns.push_back({u, Ref::player(defending), r});
                else give.back() += r;
            }
            for (std::size_t i = 0; i < list.size(); ++i)
                if (give[i] > 0) assigns.push_back({u, Ref::object(static_cast<std::uint64_t>(list[i])), give[i]});
        }
    }
    auto tkey = [this](const Ref& r) {
        if (r.is_player()) return std::make_tuple(0, 0, static_cast<int>(r.id));
        const Obj& o = obj(static_cast<int>(r.id));
        return std::make_tuple(1, o.ts, o.oid);
    };
    std::stable_sort(assigns.begin(), assigns.end(), [&](const Assign& x, const Assign& y) {
        const Obj& a = obj(x.src);
        const Obj& b = obj(y.src);
        if (a.ts != b.ts) return a.ts < b.ts;
        if (a.oid != b.oid) return a.oid < b.oid;
        return tkey(x.dst) < tkey(y.dst);
    });
    for (const Assign& as : assigns)
        deal_damage(Ref::object(static_cast<std::uint64_t>(as.src)), as.dst, as.amount);
}

}  // namespace spiremark
