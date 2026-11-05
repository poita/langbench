module tests.parser_test;

import orderbook.parser;
import orderbook.types;

unittest // all five commands, with ids that look like keywords
{
    string in_ = "6\nLIMIT BUY BUY 100 5\nLIMIT b2 SELL 101 7 IOC\nMARKET IOC BUY 3\n"
        ~ "CANCEL BOOK\nREPLACE x 99 4\nBOOK";
    auto r = parseCommands(in_);
    assert(r.commands.length == 6);
    auto c = r.commands;
    assert(c[0].kind == CmdKind.limit && c[0].side == Side.buy && c[0].tif == Tif.gtc);
    assert(in_[c[0].idOff .. c[0].idOff + c[0].idLen] == "BUY");
    assert(c[0].price == 100 && c[0].qty == 5);
    assert(c[1].side == Side.sell && c[1].tif == Tif.ioc && c[1].qty == 7);
    assert(c[2].kind == CmdKind.market && in_[c[2].idOff .. c[2].idOff + c[2].idLen] == "IOC");
    assert(c[2].qty == 3);
    assert(c[3].kind == CmdKind.cancel && in_[c[3].idOff .. c[3].idOff + c[3].idLen] == "BOOK");
    assert(c[4].kind == CmdKind.replace && c[4].price == 99 && c[4].qty == 4);
    assert(c[5].kind == CmdKind.book);
    assert(r.prices == [100, 101, 99]);
}

unittest // FOK flag, trailing newline, empty stream
{
    auto r = parseCommands("1\nLIMIT a SELL 1000000000 1000000000 FOK\n");
    assert(r.commands.length == 1 && r.commands[0].tif == Tif.fok);
    assert(r.commands[0].price == 1_000_000_000 && r.commands[0].qty == 1_000_000_000);
    assert(parseCommands("0\n").commands.length == 0);
    assert(parseCommands("0").commands.length == 0);
    assert(parseCommands("").commands.length == 0);
}
