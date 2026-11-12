#include "spiremark/script.hpp"

namespace spiremark {

std::string Ref::render() const {
    switch (kind) {
        case Kind::Player: return std::string(1, player_char(static_cast<int>(id)));
        case Kind::Object: return "#" + std::to_string(id);
        case Kind::Entry: return "~" + std::to_string(id);
        case Kind::None: break;
    }
    return "";
}

const char* err_name(ErrKind e) {
    switch (e) {
        case ErrKind::BadSyntax: return "bad-syntax";
        case ErrKind::GameOver: return "game-over";
        case ErrKind::NotYourTurn: return "not-your-turn";
        case ErrKind::WrongDecision: return "wrong-decision";
        case ErrKind::NoSuchCard: return "no-such-card";
        case ErrKind::BadTiming: return "bad-timing";
        case ErrKind::BadTargetCount: return "bad-target-count";
        case ErrKind::IllegalTarget: return "illegal-target";
        case ErrKind::CannotAfford: return "cannot-afford";
        case ErrKind::NoSuchObject: return "no-such-object";
        case ErrKind::NoSuchAbility: return "no-such-ability";
        case ErrKind::CostUnpayable: return "cost-unpayable";
        case ErrKind::DuplicateAttacker: return "duplicate-attacker";
        case ErrKind::IllegalAttacker: return "illegal-attacker";
        case ErrKind::MissingRequiredAttacker: return "missing-required-attacker";
        case ErrKind::DuplicateBlocker: return "duplicate-blocker";
        case ErrKind::IllegalBlocker: return "illegal-blocker";
        case ErrKind::MissingRequiredBlock: return "missing-required-block";
    }
    return "";
}

namespace {

bool is_blank(char c) { return c == ' ' || c == '\t'; }

std::vector<std::string> split_words(const std::string& line) {
    std::vector<std::string> words;
    std::size_t i = 0;
    while (i < line.size()) {
        while (i < line.size() && is_blank(line[i])) ++i;
        std::size_t start = i;
        while (i < line.size() && !is_blank(line[i])) ++i;
        if (i > start) words.push_back(line.substr(start, i - start));
    }
    return words;
}

/// Parses a non-empty run of decimal digits into a uint64; false on overflow
/// or any other character.
bool parse_u64(const std::string& s, std::uint64_t& out) {
    if (s.empty()) return false;
    std::uint64_t v = 0;
    for (char c : s) {
        if (c < '0' || c > '9') return false;
        unsigned d = static_cast<unsigned>(c - '0');
        if (v > (UINT64_MAX - d) / 10) return false;
        v = v * 10 + d;
    }
    out = v;
    return true;
}

bool parse_in_range(const std::string& s, std::uint64_t lo, std::uint64_t hi, std::uint64_t& out) {
    std::uint64_t v;
    if (!parse_u64(s, v) || v < lo || v > hi) return false;
    out = v;
    return true;
}

bool parse_objref(const std::string& s, std::uint64_t& out) {
    return s.size() >= 2 && s[0] == '#' && parse_u64(s.substr(1), out);
}

bool parse_target(const std::string& s, Ref& out) {
    if (s == "A") { out = Ref::player(0); return true; }
    if (s == "B") { out = Ref::player(1); return true; }
    std::uint64_t v;
    if (s.size() >= 2 && s[0] == '#' && parse_u64(s.substr(1), v)) { out = Ref::object(v); return true; }
    if (s.size() >= 2 && s[0] == '~' && parse_u64(s.substr(1), v)) { out = Ref::entry(v); return true; }
    return false;
}

}  // namespace

std::vector<std::string> split_lines(const std::string& input) {
    std::vector<std::string> lines;
    std::size_t start = 0;
    while (start < input.size()) {
        std::size_t nl = input.find('\n', start);
        std::string line;
        if (nl == std::string::npos) {
            line = input.substr(start);
            start = input.size();
        } else {
            line = input.substr(start, nl - start);
            start = nl + 1;
        }
        if (!line.empty() && line.back() == '\r') line.pop_back();
        lines.push_back(std::move(line));
    }
    return lines;
}

bool is_comment_line(const std::string& line) {
    for (char c : line) {
        if (is_blank(c)) continue;
        return c == '#';
    }
    return true;
}

MatchSetup parse_setup(const std::vector<std::string>& lines, std::size_t& start_line) {
    MatchSetup m;
    bool have_cards = false, have_seed = false;
    bool seen_spire = false, seen_opening = false, seen_maxcap = false, seen_handmax = false,
         seen_turnlimit = false, seen_first = false, seen_shuffle = false, seen_trace = false;
    bool seen_cap[2] = {false, false};

    auto bad = [](const char* why) { throw SetupError(why); };
    auto number = [&](const std::vector<std::string>& w, std::uint64_t lo, std::uint64_t hi) {
        if (w.size() != 2) bad("setup arity");
        std::uint64_t v;
        if (!parse_in_range(w[1], lo, hi, v)) bad("setup number");
        return v;
    };
    auto once = [&](bool& flag) {
        if (flag) bad("duplicate setup line");
        flag = true;
    };

    for (std::size_t i = 0; i < lines.size(); ++i) {
        if (is_comment_line(lines[i])) continue;
        std::vector<std::string> w = split_words(lines[i]);
        const std::string& d = w[0];
        if (d == "START") {
            if (w.size() != 1) bad("START takes no argument");
            if (!have_cards || !have_seed) bad("missing CARDS or SEED");
            start_line = i;
            return m;
        } else if (d == "CARDS") {
            once(have_cards);
            if (w.size() != 2) bad("CARDS arity");
            m.cards_path = w[1];
        } else if (d == "SEED") {
            once(have_seed);
            m.seed = number(w, 0, UINT64_MAX);
        } else if (d == "SPIRE") {
            once(seen_spire);
            m.spire = static_cast<int>(number(w, 1, 1000000));
        } else if (d == "OPENING") {
            once(seen_opening);
            m.opening = static_cast<int>(number(w, 0, 20));
        } else if (d == "MAXCAP") {
            once(seen_maxcap);
            m.maxcap = static_cast<int>(number(w, 1, 100));
        } else if (d == "HANDMAX") {
            once(seen_handmax);
            m.handmax = static_cast<int>(number(w, 0, 100));
        } else if (d == "TURNLIMIT") {
            once(seen_turnlimit);
            m.turnlimit = static_cast<int>(number(w, 1, 100000));
        } else if (d == "FIRST") {
            once(seen_first);
            if (w.size() != 2 || (w[1] != "A" && w[1] != "B")) bad("FIRST");
            m.first = w[1] == "A" ? 0 : 1;
        } else if (d == "SHUFFLE") {
            once(seen_shuffle);
            if (w.size() != 2 || (w[1] != "on" && w[1] != "off")) bad("SHUFFLE");
            m.shuffle = w[1] == "on";
        } else if (d == "TRACE") {
            once(seen_trace);
            if (w.size() != 2) bad("TRACE");
            if (w[1] == "none") m.trace = TraceMode::None;
            else if (w[1] == "legal") m.trace = TraceMode::Legal;
            else if (w[1] == "state") m.trace = TraceMode::State;
            else bad("TRACE");
        } else if (d == "CAP") {
            if (w.size() != 3 || (w[1] != "A" && w[1] != "B")) bad("CAP");
            int p = w[1] == "A" ? 0 : 1;
            once(seen_cap[p]);
            std::uint64_t v;
            if (!parse_in_range(w[2], 0, 100, v)) bad("CAP number");
            m.cap[p] = static_cast<int>(v);
        } else if (d == "DECK" || d == "HAND" || d == "FIELD" || d == "ASH" || d == "RIFT") {
            if (w.size() < 3 || (w[1] != "A" && w[1] != "B")) bad("zone line");
            int z = d == "DECK" ? 0 : d == "HAND" ? 1 : d == "FIELD" ? 2 : d == "ASH" ? 3 : 4;
            int p = w[1] == "A" ? 0 : 1;
            for (std::size_t k = 2; k < w.size(); ++k) {
                SetupEntry e;
                std::size_t star = w[k].find('*');
                if (star == std::string::npos) {
                    e.card_id = w[k];
                } else {
                    e.card_id = w[k].substr(0, star);
                    std::uint64_t c;
                    if (!parse_in_range(w[k].substr(star + 1), 1, 1000, c)) bad("entry count");
                    e.count = static_cast<int>(c);
                }
                if (e.card_id.empty() || e.card_id.find('*') != std::string::npos) bad("entry id");
                m.zones[z][p].push_back(std::move(e));
            }
        } else {
            bad("unknown setup word");
        }
    }
    bad("missing START");
    return m;
}

ScriptLine parse_script_line(const std::string& line) {
    ScriptLine out;
    if (is_comment_line(line)) return out;
    out.kind = ScriptLine::Kind::BadSyntax;
    std::vector<std::string> w = split_words(line);
    const std::string& first = w[0];

    if (first == "DUMP" || first == "LEGAL" || first == "VAULT") {
        if (w.size() != 1) return out;
        out.kind = ScriptLine::Kind::Directive;
        out.directive = first == "DUMP" ? DirectiveType::Dump
                      : first == "LEGAL" ? DirectiveType::Legal : DirectiveType::Vault;
        return out;
    }
    if (first == "CARD") {
        if (w.size() != 2) return out;
        out.kind = ScriptLine::Kind::Directive;
        out.directive = DirectiveType::Card;
        out.card_id = w[1];
        return out;
    }
    if ((first != "A" && first != "B") || w.size() < 2) return out;
    Action a;
    a.player = first == "A" ? 0 : 1;
    const std::string& verb = w[1];
    if (verb == "PASS" || verb == "CONCEDE") {
        if (w.size() != 2) return out;
        a.type = verb == "PASS" ? ActionType::Pass : ActionType::Concede;
    } else if (verb == "PLAY") {
        if (w.size() < 3) return out;
        a.type = ActionType::Play;
        if (!parse_u64(w[2], a.pos)) return out;
        for (std::size_t i = 3; i < w.size(); ++i) {
            Ref r;
            if (!parse_target(w[i], r)) return out;
            a.targets.push_back(r);
        }
    } else if (verb == "ACT") {
        if (w.size() < 4) return out;
        a.type = ActionType::Act;
        if (!parse_objref(w[2], a.oid) || !parse_u64(w[3], a.index)) return out;
        for (std::size_t i = 4; i < w.size(); ++i) {
            Ref r;
            if (!parse_target(w[i], r)) return out;
            a.targets.push_back(r);
        }
    } else if (verb == "ATTACK") {
        a.type = ActionType::Attack;
        for (std::size_t i = 2; i < w.size(); ++i) {
            std::uint64_t v;
            if (!parse_objref(w[i], v)) return out;
            a.attackers.push_back(v);
        }
    } else if (verb == "BLOCK") {
        a.type = ActionType::Block;
        for (std::size_t i = 2; i < w.size(); ++i) {
            std::size_t colon = w[i].find(':');
            if (colon == std::string::npos) return out;
            std::uint64_t b, t;
            if (!parse_objref(w[i].substr(0, colon), b) || !parse_objref(w[i].substr(colon + 1), t))
                return out;
            a.blocks.emplace_back(b, t);
        }
    } else {
        return out;
    }
    out.kind = ScriptLine::Kind::Action;
    out.action = std::move(a);
    return out;
}

}  // namespace spiremark
