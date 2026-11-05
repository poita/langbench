module tests.driver_test;

import orderbook.driver;

unittest // SPEC.md example 1
{
    enum input = "9\nLIMIT s1 SELL 101 5\nLIMIT s2 SELL 103 5\nLIMIT s3 SELL 102 5\n"
        ~ "LIMIT s4 SELL 104 5\nLIMIT b1 BUY 103 12\nBOOK\nLIMIT b2 BUY 110 1\n"
        ~ "LIMIT b3 BUY 103 9\nBOOK\n";
    enum expected = "REST s1\nREST s2\nREST s3\nREST s4\nTRADE b1 s1 101 5\nFILLED s1\n"
        ~ "TRADE b1 s3 102 5\nFILLED s3\nTRADE b1 s2 103 2\nFILLED b1\n"
        ~ "ASK 103 3 1\nASK 104 5 1\n--\nTRADE b2 s2 103 1\nFILLED b2\n"
        ~ "TRADE b3 s2 103 2\nFILLED s2\nREST b3\nBID 103 7 1\nASK 104 5 1\n--\n";
    assert(processToString(input) == expected);
}

unittest // SPEC.md example 2 (IOC, rejected cancel/replace), no final newline
{
    enum input = "11\nLIMIT s1 SELL 100 5\nLIMIT s2 SELL 101 5\nLIMIT b1 BUY 100 8 IOC\nBOOK\n"
        ~ "LIMIT b2 BUY 99 8 IOC\nLIMIT b3 BUY 101 5 IOC\nBOOK\nCANCEL b1\n"
        ~ "REPLACE b1 100 1\nLIMIT s3 SELL 50 1 IOC\nBOOK";
    enum expected = "REST s1\nREST s2\nTRADE b1 s1 100 5\nFILLED s1\nCANCEL b1 3\n"
        ~ "ASK 101 5 1\n--\nCANCEL b2 8\nTRADE b3 s2 101 5\nFILLED s2\nFILLED b3\n--\n"
        ~ "REJECT b1\nREJECT b1\nCANCEL s3 1\n--\n";
    assert(processToString(input) == expected);
}

unittest // N = 0 prints nothing; ids may equal keywords
{
    assert(processToString("0\n") == "");
    assert(processToString("3\nLIMIT BOOK SELL 5 1\nMARKET CANCEL BUY 1\nCANCEL BOOK\n")
        == "REST BOOK\nTRADE CANCEL BOOK 5 1\nFILLED BOOK\nFILLED CANCEL\nREJECT BOOK\n");
}
