"""Run a complete match file and produce the output text."""

from __future__ import annotations

from .database import load_database
from .dump import card_block, dump_lines, legal_block, vault_lines
from .engine import Game
from .errors import DatabaseError, SetupError
from .matchfile import parse_script_line, parse_setup, split_lines

__all__ = ["run_match"]


def _setup_game(lines: list[str]):
    """Steps 1-3 of SPEC section 8.  Returns ``(game, first script index)``."""
    cfg, start = parse_setup(lines)
    try:
        db = load_database(cfg.cards)
    except DatabaseError:
        raise SetupError("bad-database") from None
    for zone in cfg.zones.values():
        for entries in zone.values():
            for cid, _ in entries:
                if cid not in db:
                    raise SetupError("unknown-card")
    return Game(cfg, db), start


def run_match(text: str) -> str:
    """Simulate the match described by *text*; return the full output."""
    lines = split_lines(text)
    try:
        game, start = _setup_game(lines)
    except SetupError as exc:
        return "FATAL %s\n" % exc.kind
    game.start()
    trace = game.cfg.trace
    for i in range(start, len(lines)):
        cmd = parse_script_line(lines[i])
        if cmd is False:
            continue
        lineno = i + 1
        if cmd is None:
            game.line("ERR %d bad-syntax" % lineno)
            continue
        kind = cmd.kind
        if kind == "DUMP":
            game.out.extend(dump_lines(game))
        elif kind == "LEGAL":
            game.out.extend(legal_block(game))
        elif kind == "VAULT":
            game.out.extend(vault_lines(game))
        elif kind == "CARD":
            game.out.extend(card_block(cmd.card_id,
                                       game.db.get(cmd.card_id)))
        else:
            err = game.submit(cmd.action)
            if err is not None:
                game.line("ERR %d %s" % (lineno, err))
            elif trace == "legal":
                game.out.extend(legal_block(game))
            elif trace == "state":
                game.out.extend(dump_lines(game))
    game.finish_pending()
    return "\n".join(game.out) + "\n"
