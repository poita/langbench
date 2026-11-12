#include "spiremark/card.hpp"

#include <algorithm>

namespace spiremark {

namespace {
const char* const kKwNames[] = {
    "vanguard", "vigil", "riposte", "pierce", "ghostwalk", "skyhook", "venom", "siphon",
    "plating", "provoke", "spectral", "tenacity", "siegework", "shackled", "relentless",
    "swift"};
const char* const kEventNames[] = {
    "arrive", "leave", "dies", "ally-arrive", "enemy-arrive", "ally-dies", "enemy-dies",
    "turn-start", "your-turn-start", "turn-end", "your-turn-end", "attacks", "blocks",
    "blocked", "unblocked", "damaged", "deals-damage", "you-play-rite", "enemy-plays-rite",
    "you-draw", "spire-loss", "enemy-spire-loss", "end-of-combat"};
}  // namespace

const char* keyword_name(Kw k) { return kKwNames[static_cast<int>(k)]; }

bool keyword_from_name(const std::string& name, Kw& out) {
    for (int i = 0; i < static_cast<int>(Kw::Count); ++i) {
        if (name == kKwNames[i]) {
            out = static_cast<Kw>(i);
            return true;
        }
    }
    return false;
}

std::string KwSpec::render() const {
    std::string s = keyword_name(kw);
    if (kw == Kw::Plating) s += ":" + std::to_string(value);
    return s;
}

bool compare(Cmp c, std::int64_t l, std::int64_t r) {
    switch (c) {
        case Cmp::Le: return l <= r;
        case Cmp::Lt: return l < r;
        case Cmp::Eq: return l == r;
        case Cmp::Ge: return l >= r;
        case Cmp::Gt: return l > r;
        case Cmp::Ne: return l != r;
    }
    return false;
}

const char* when_name(When w) {
    switch (w) {
        case When::TurnEnd: return "turn-end";
        case When::EndOfCombat: return "end-of-combat";
        case When::YourNextTurnStart: return "your-next-turn-start";
    }
    return "";
}

bool event_from_name(const std::string& name, Event& out) {
    for (int i = 0; i < static_cast<int>(Event::Count); ++i) {
        if (name == kEventNames[i]) {
            out = static_cast<Event>(i);
            return true;
        }
    }
    return false;
}

bool Card::has_tag(const std::string& t) const {
    return std::find(tags.begin(), tags.end(), t) != tags.end();
}

const char* card_type_name(CardType t) {
    switch (t) {
        case CardType::Unit: return "unit";
        case CardType::Rite: return "rite";
        case CardType::Relic: return "relic";
    }
    return "";
}

}  // namespace spiremark
