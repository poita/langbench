#include "spiremark/session.hpp"

#include <ostream>

#include "spiremark/database.hpp"
#include "spiremark/game.hpp"
#include "spiremark/script.hpp"

namespace spiremark {

void run_match(const std::string& input, std::ostream& out) {
    std::vector<std::string> lines = split_lines(input);
    std::size_t start = 0;
    MatchSetup setup;
    try {
        setup = parse_setup(lines, start);
    } catch (const SetupError&) {
        out << "FATAL bad-setup\n";
        return;
    }
    std::unique_ptr<Database> db;
    try {
        db = std::make_unique<Database>(Database::load_file(setup.cards_path));
    } catch (const DatabaseError&) {
        out << "FATAL bad-database\n";
        return;
    }
    GameSetup gs;
    if (!resolve_setup(setup, *db, gs)) {
        out << "FATAL unknown-card\n";
        return;
    }
    Game game(*db, gs, out);
    for (std::size_t i = start + 1; i < lines.size(); ++i) {
        ScriptLine sl = parse_script_line(lines[i]);
        std::size_t lineno = i + 1;
        switch (sl.kind) {
            case ScriptLine::Kind::Comment: break;
            case ScriptLine::Kind::BadSyntax:
                out << "ERR " << lineno << " " << err_name(ErrKind::BadSyntax) << '\n';
                break;
            case ScriptLine::Kind::Directive:
                switch (sl.directive) {
                    case DirectiveType::Dump: game.print_dump(); break;
                    case DirectiveType::Legal: game.print_legal(); break;
                    case DirectiveType::Vault: game.print_vault(); break;
                    case DirectiveType::Card: game.print_card(sl.card_id); break;
                }
                break;
            case ScriptLine::Kind::Action: {
                auto err = game.apply(sl.action);
                if (err) {
                    out << "ERR " << lineno << " " << err_name(*err) << '\n';
                } else if (setup.trace == TraceMode::State) {
                    game.print_dump();
                } else if (setup.trace == TraceMode::Legal) {
                    game.print_legal();
                }
                break;
            }
        }
    }
    game.finish();
}

}  // namespace spiremark
