/// Spec worked examples run end to end through `processStream`.
module tests.examples;

import std.array : appender;

import orderbook;

private string runText(string input)
{
    auto w = appender!string;
    auto sink = textSink(w);
    processStream(new OrderBook, input, sink);
    return w[];
}

unittest // example 1: sweeping levels, price improvement, FIFO
{
    immutable input = "9\nLIMIT s1 SELL 101 5\nLIMIT s2 SELL 103 5\nLIMIT s3 SELL 102 5\n"
        ~ "LIMIT s4 SELL 104 5\nLIMIT b1 BUY 103 12\nBOOK\nLIMIT b2 BUY 110 1\n"
        ~ "LIMIT b3 BUY 103 9\nBOOK\n";
    immutable expected = "REST s1\nREST s2\nREST s3\nREST s4\nTRADE b1 s1 101 5\nFILLED s1\n"
        ~ "TRADE b1 s3 102 5\nFILLED s3\nTRADE b1 s2 103 2\nFILLED b1\nASK 103 3 1\n"
        ~ "ASK 104 5 1\n--\nTRADE b2 s2 103 1\nFILLED b2\nTRADE b3 s2 103 2\nFILLED s2\n"
        ~ "REST b3\nBID 103 7 1\nASK 104 5 1\n--\n";
    assert(runText(input) == expected);
}

unittest // example 2: IOC, cancel/replace of non-resting orders
{
    immutable input = "11\nLIMIT s1 SELL 100 5\nLIMIT s2 SELL 101 5\nLIMIT b1 BUY 100 8 IOC\nBOOK\n"
        ~ "LIMIT b2 BUY 99 8 IOC\nLIMIT b3 BUY 101 5 IOC\nBOOK\nCANCEL b1\nREPLACE b1 100 1\n"
        ~ "LIMIT s3 SELL 50 1 IOC\nBOOK";
    immutable expected = "REST s1\nREST s2\nTRADE b1 s1 100 5\nFILLED s1\nCANCEL b1 3\n"
        ~ "ASK 101 5 1\n--\nCANCEL b2 8\nTRADE b3 s2 101 5\nFILLED s2\nFILLED b3\n--\n"
        ~ "REJECT b1\nREJECT b1\nCANCEL s3 1\n--\n";
    assert(runText(input) == expected);
}

unittest // example 3: REPLACE priority rules and an aggressive replace
{
    immutable input = "10\nLIMIT b1 BUY 100 10\nLIMIT s1 SELL 105 4\nLIMIT s2 SELL 106 4\n"
        ~ "REPLACE b1 105 6\nBOOK\nREPLACE b1 110 20\nBOOK\nREPLACE b1 110 3\nCANCEL b1\nBOOK\n";
    immutable expected = "REST b1\nREST s1\nREST s2\nTRADE b1 s1 105 4\nFILLED s1\nREST b1\n"
        ~ "BID 105 2 1\nASK 106 4 1\n--\nTRADE b1 s2 106 4\nFILLED s2\nREST b1\n"
        ~ "BID 110 16 1\n--\nREST b1\nCANCEL b1 3\n--\n";
    assert(runText(input) == expected);
}

unittest // empty input, ids equal to keywords
{
    assert(runText("0") == "");
    assert(runText("0\n") == "");
    assert(runText("3\nLIMIT BOOK BUY 5 1\nCANCEL BOOK\nCANCEL BOOK\n")
            == "REST BOOK\nCANCEL BOOK 1\nREJECT BOOK\n");
}
