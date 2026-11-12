// Small vocabulary types shared by the script parser and the engine.
#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace spiremark {

/// Players are 0 (A) and 1 (B).
inline int opponent(int p) { return 1 - p; }
inline char player_char(int p) { return p == 0 ? 'A' : 'B'; }

/// A reference to a player, an object (oid) or a Chain entry (cid).
struct Ref {
    enum class Kind : std::uint8_t { None, Player, Object, Entry };
    Kind kind = Kind::None;
    std::uint64_t id = 0;

    static Ref none() { return {}; }
    static Ref player(int p) { return {Kind::Player, static_cast<std::uint64_t>(p)}; }
    static Ref object(std::uint64_t oid) { return {Kind::Object, oid}; }
    static Ref entry(std::uint64_t cid) { return {Kind::Entry, cid}; }

    bool is_player() const { return kind == Kind::Player; }
    bool is_object() const { return kind == Kind::Object; }
    bool is_entry() const { return kind == Kind::Entry; }
    bool operator==(const Ref& o) const { return kind == o.kind && id == o.id; }
    bool operator!=(const Ref& o) const { return !(*this == o); }
    /// `A`, `B`, `#7` or `~3` (empty for None).
    std::string render() const;
};

/// The kinds of player action of SPEC.md section 4.2.
enum class ActionType { Pass, Concede, Play, Act, Attack, Block };

struct Action {
    ActionType type = ActionType::Pass;
    int player = 0;
    std::uint64_t pos = 0;     ///< PLAY: 1-based hand position
    std::uint64_t oid = 0;     ///< ACT: the object
    std::uint64_t index = 0;   ///< ACT: 1-based ability number
    std::vector<Ref> targets;  ///< PLAY / ACT
    std::vector<std::uint64_t> attackers;                              ///< ATTACK
    std::vector<std::pair<std::uint64_t, std::uint64_t>> blocks;       ///< BLOCK blocker:attacker
};

/// Reasons an action line is rejected (SPEC.md section 24).
enum class ErrKind {
    BadSyntax, GameOver, NotYourTurn, WrongDecision,
    NoSuchCard, BadTiming, BadTargetCount, IllegalTarget, CannotAfford,
    NoSuchObject, NoSuchAbility, CostUnpayable,
    DuplicateAttacker, IllegalAttacker, MissingRequiredAttacker,
    DuplicateBlocker, IllegalBlocker, MissingRequiredBlock
};
const char* err_name(ErrKind e);

}  // namespace spiremark
