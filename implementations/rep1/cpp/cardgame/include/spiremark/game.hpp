// The Spiremark rules engine (SPEC.md sections 7-22).
//
// A `Game` simulates one match. It is a resumable state machine: construct it
// (which performs setup and runs to the first decision point), then feed it
// player actions with `apply`. Every rules event is written as one numbered
// line to the output stream given at construction.
#pragma once

#include <deque>
#include <iosfwd>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "spiremark/card.hpp"
#include "spiremark/database.hpp"
#include "spiremark/detail/format.hpp"
#include "spiremark/rng.hpp"
#include "spiremark/script.hpp"
#include "spiremark/types.hpp"

namespace spiremark {

/// Resolved (validated) setup: the database cards each zone is filled with.
struct GameSetup {
    MatchSetup match;
    /// cards[z][player] in oid-assignment order; z as in MatchSetup::zones.
    std::vector<const Card*> cards[5][2];
};

/// Builds a GameSetup, resolving card ids against `db`.
/// Returns false (and leaves `out` unspecified) if some card id is unknown.
bool resolve_setup(const MatchSetup& m, const Database& db, GameSetup& out);

class Game {
public:
    /// Performs setup (SPEC.md section 8) and runs to the first decision point.
    /// `out` receives event lines and inspection blocks; it must outlive the Game.
    Game(const Database& db, const GameSetup& setup, std::ostream& out);

    /// Applies one script action. Returns the error kind if the action is
    /// rejected (nothing happens then), or nullopt if it was accepted, in which
    /// case the engine has run forward to the next decision point.
    std::optional<ErrKind> apply(const Action& a);

    /// Emits the final `RESULT pending none` if the match is still running.
    void finish();

    bool over() const { return over_; }

    /// Inspection blocks (SPEC.md section 23), written to the output stream.
    void print_dump();
    void print_legal();
    void print_vault();
    /// Prints the `CARD` block of any id of the database.
    void print_card(const std::string& id) { out_ << db_.describe(id); }

private:
    // ------------------------------------------------------------ types --
    enum class Zone : std::uint8_t { Vault, Hand, Field, Ash, Rift, Stack };
    enum class Step : std::uint8_t {
        Dawn, Draw, Main1, ClashAttack, ClashBlock, ClashRiposte, ClashDamage,
        ClashEnd, Main2, DuskTrigger, DuskDiscard, DuskCleanup
    };
    enum class DecisionKind : std::uint8_t { None, Priority, Attackers, Blockers };
    enum class EntryKind : std::uint8_t { Rite, Unit, Relic, Ability, Trigger };
    enum class RecKind : std::uint8_t { Modify, Setbody, Swapstats, Grant, Strip, Control, Cheaper };

    struct Obj {
        int oid = 0;
        const Card* card = nullptr;
        int owner = 0;
        Zone zone = Zone::Stack;
        int ts = 0;
        int base_ctrl = 0;
        int last_ctrl = 0;  // controller when it last left the Field (owner initially)
        // Field state (7.5)
        bool exhausted = false;
        bool doomed = false;
        bool attacking = false, blocking = false, blocked = false;
        bool tenacity_used = false;
        std::int64_t wounds = 0, counters = 0, ward = 0;
        int since = 0;
        int blocking_oid = 0;
        std::vector<int> blockers;
        std::vector<int> once;
        // Derived (valid for Field objects after derive())
        int ctrl = 0;
        std::int64_t edge = 0, core = 0;
        std::uint32_t kw_mask = 0;
        std::int64_t plating = 0;
        bool stripped = false;
    };

    struct Target {
        Ref ref;
        bool removed = false;
    };

    struct Entry {
        int cid = 0;
        EntryKind kind = EntryKind::Rite;
        int controller = 0;
        int source = 0;
        int index = 0;
        std::vector<Target> targets;
        const std::vector<TargetSpec>* specs = nullptr;
        const std::vector<Effect>* delayed_effects = nullptr;
        Ref it;
    };

    struct AuraOut {
        RecKind kind = RecKind::Modify;
        bool active = false;
        std::int64_t a = 0, b = 0;
        KwSpec kw;
        std::vector<int> objs;
        std::int64_t cheaper = 0;
        const std::vector<Filter>* card_filters = nullptr;
    };

    struct Record {
        int eid = 0, ts = 0;
        int controller = 0;
        int source = 0;
        RecKind kind = RecKind::Modify;
        bool aura = false;
        std::int64_t a = 0, b = 0;
        KwSpec kw;
        std::vector<int> affected;         // discrete records
        const Ability* ability = nullptr;  // aura records
        std::vector<AuraOut> outs;         // aura records, recomputed by derive()
        int eff_controller = 0;            // aura records, recomputed by derive()
    };

    struct Delayed {
        int ts = 0;
        int controller = 0;
        int source = 0;
        When when = When::TurnEnd;
        std::vector<Target> targets;
        const std::vector<TargetSpec>* specs = nullptr;
        const std::vector<Effect>* effects = nullptr;
    };

    struct Pending {
        int controller = 0;
        int ts = 0;
        int oid = 0;
        int index = 0;
        int source = 0;
        Ref it;
        // delayed triggers only
        const std::vector<Effect>* effects = nullptr;
        const std::vector<TargetSpec>* specs = nullptr;
        std::vector<Target> targets;
    };

    struct Ctx {
        int controller = 0;
        int source = 0;
        Ref it;
        const std::vector<Target>* targets = nullptr;
        const std::vector<TargetSpec>* specs = nullptr;
        int that = 0;
        bool aura = false;
    };

    struct Decision {
        DecisionKind kind = DecisionKind::None;
        int player = 0;
    };

    struct CheaperRec {
        int controller;
        std::int64_t amount;
        const std::vector<Filter>* filters;
    };

    // ------------------------------------------------------------ state --
    std::ostream& out_;
    const Database& db_;
    MatchSetup cfg_;
    Rng rng_;
    long long seq_ = 0;

    std::deque<Obj> objs_;  // index = oid (slot 0 unused); deque keeps references stable
    std::deque<int> vault_[2];
    std::vector<int> hand_[2], ash_[2], rift_[2];
    std::vector<int> field_;  // canonical order (timestamps increase on entry)
    std::int64_t spire_[2] = {0, 0}, ember_[2] = {0, 0}, cap_[2] = {0, 0}, shield_[2] = {0, 0};
    std::string loss_reason_[2];

    std::vector<Entry> chain_;  // bottom first
    std::vector<Record> records_;
    std::vector<Delayed> delayed_;
    std::vector<Pending> pending_;
    std::vector<CheaperRec> cheaper_;

    int next_cid_ = 1, next_eid_ = 1, next_ts_ = 1;
    int turn_ = 1;
    int active_ = 0;
    Step cur_step_ = Step::Dawn;
    Step next_step_ = Step::Dawn;
    Decision decision_;
    int holder_ = 0;
    int pass_count_ = 0;
    bool over_ = false;
    std::string result_winner_, result_reason_;
    bool no_triggers_ = false;
    bool dirty_ = true;
    bool deriving_ = false;
    // combat bookkeeping for the clash-damage step
    std::set<int> riposted_;

    // -------------------------------------------------------- game_state --
    Obj& obj(int oid) { return objs_[static_cast<std::size_t>(oid)]; }
    const Obj& obj(int oid) const { return objs_[static_cast<std::size_t>(oid)]; }
    bool valid_oid(std::uint64_t oid) const { return oid >= 1 && oid < objs_.size(); }
    bool on_field(int oid) const { return obj(oid).zone == Zone::Field; }
    void touch() { dirty_ = true; }
    int new_object(const Card* c, int owner);
    void emit_line(const std::string& body);
    template <class... A>
    void emit(const char* name, const A&... fields) { emit_line(detail::build(name, fields...)); }
    void remove_from_zone(Obj& o);
    void place_in_zone(Obj& o, Zone z);
    void setup(const GameSetup& s);

    // ------------------------------------------------------------ layers --
    void derive();
    void ensure_derived() { if (dirty_ && !deriving_) derive(); }
    void create_aura_records(Obj& o);
    int ctrl_of(int oid);                         // current controller (Field) or owner/last
    std::int64_t cur_edge(int oid);
    std::int64_t cur_core(int oid);
    bool has_kw(int oid, Kw k);
    std::int64_t plating_of(int oid);
    std::string kwlist(const Obj& o) const;
    bool is_settling(const Obj& o) const { return o.zone == Zone::Field && o.since >= turn_; }
    void eval_statics(const std::vector<Static>& sts, Ctx& ctx, bool active, Record& rec);
    std::int64_t effective_cost(const Card& c, int player);

    // ----------------------------------------------------------- effects --
    bool match_filter(const Obj& o, const Filter& f, const Ctx& ctx);
    bool match_filters(const Obj& o, const std::vector<Filter>& fs, const Ctx& ctx);
    std::int64_t base_edge(const Obj& o) const { return o.card->edge + (o.zone == Zone::Field ? o.counters : 0); }
    std::int64_t base_core(const Obj& o) const { return o.card->core + (o.zone == Zone::Field ? o.counters : 0); }
    std::vector<int> eval_objs(const Selector& s, Ctx& ctx);
    std::vector<int> eval_players(const Selector& s, Ctx& ctx);
    std::vector<Ref> eval_dsel(const Selector& s, Ctx& ctx);
    std::int64_t eval_amount(const Amount& a, Ctx& ctx);
    bool eval_cond(const Condition& c, Ctx& ctx);
    void run_effects(const std::vector<Effect>& es, Ctx& ctx);
    void run_effect(const Effect& e, Ctx& ctx);
    void sort_canonical(std::vector<int>& v);

    // primitive state changes (SPEC.md section 17)
    void deal_damage(Ref src, Ref dst, std::int64_t n);
    void destroy_obj(int oid);
    void sacrifice_obj(int oid);
    void leave_field(int oid, const char* verb, bool is_death, bool fire_leave);
    void exile_obj(int oid);
    void bounce_obj(int oid);
    void draw_cards(int p, std::int64_t n);
    bool draw_one(int p);
    void discard_one(int p);
    void mill_one(int p);
    void change_spire(int p, std::int64_t delta);
    void gain_ember(int p, std::int64_t n);
    void raise_cap(int p, std::int64_t n);
    void add_counters(int oid, std::int64_t delta);
    void set_exhausted(int oid, bool ex);
    void doom_obj(int oid);
    void enter_field(int oid, int controller, bool fire);
    void create_objects(const Effect& e, Ctx& ctx);
    void do_dig(const Effect& e, int p, Ctx& ctx);
    void make_record(const Effect& e, Ctx& ctx);
    void make_control(Ctx& ctx, const std::vector<int>& objs);
    void remove_from_combat(int oid);
    void negate_entry(int cid);
    void make_delay(const Effect& e, Ctx& ctx);

    // ------------------------------------------------------------- chain --
    Entry* find_entry(int cid);
    bool target_legal(const TargetSpec& s, Ref r, int controller, int source, int self_cid);
    std::vector<Ref> candidates(const TargetSpec& s, int controller, int source, int self_cid);
    std::vector<std::vector<Ref>> target_tuples(const std::vector<TargetSpec>& specs,
                                                int controller, int source, int self_cid);
    std::string render_targets(const std::vector<Target>& ts, bool show_removed) const;
    std::string render_ref_list(const std::vector<Ref>& rs) const;
    bool play_timing_ok(const Obj& o, int player);
    bool costs_payable(const Obj& o, const Ability& ab, int player, int index);
    std::optional<ErrKind> do_play(const Action& a);
    std::optional<ErrKind> do_act(const Action& a);
    void pay_costs(Obj& o, const Ability& ab, int player, int index);
    void resolve_top();
    void after_player_action(int actor);

    // ---------------------------------------------------------- triggers --
    void collect_self(Event ev, int oid, Ref it, bool force, int controller);
    void collect_all(Event ev, int ctrl_filter, bool use_ctrl, Ref it);
    void collect_arrive(int oid);
    void collect_death(int oid, int ctrl_at_leave, bool died, bool left);
    void collect_spire_loss(int p);
    bool settle();
    bool state_checks();
    bool push_triggers();
    void drain();
    bool check_losses();
    void end_with_draw(const char* reason);

    // ------------------------------------------------------------- turns --
    void run();
    void enter(Step s);
    void do_dawn();
    void do_cleanup();
    void start_round();
    void finish_round();
    void apply_pass();
    void declare_attackers(std::vector<int> atk);
    void declare_blockers(std::vector<std::pair<int, int>> pairs);
    void deal_combat(bool riposte_step);
    bool can_attack(int oid);
    bool can_block(int b, int a);
    bool any_riposte_in_combat();
    bool in_combat(const Obj& o) const { return o.zone == Zone::Field && (o.attacking || o.blocking); }
    std::optional<ErrKind> do_attack(const Action& a);
    std::optional<ErrKind> do_block(const Action& a);

    // ------------------------------------------------------------ report --
    const char* step_name(Step s) const;
    std::string player_line(int p) const;
};

}  // namespace spiremark
