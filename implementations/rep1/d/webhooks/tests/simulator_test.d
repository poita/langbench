module simulator_test;

import webhooks.commands : processString;
import webhooks.heap;

@("heap: pops in (time, delivery) order")
unittest
{
    auto h = SlotHeap(4);
    h.push(Slot(5, 2));
    h.push(Slot(1, 9));
    h.push(Slot(5, 1));
    h.push(Slot(-3, 7));
    h.push(Slot(1, 3)); // exceeds reserved capacity; heap grows
    Slot[] order;
    while (!h.empty)
        order ~= h.pop();
    assert(order == [Slot(-3, 7), Slot(1, 3), Slot(1, 9), Slot(5, 1), Slot(5, 2)]);
}

@("simulate: spec worked example")
unittest
{
    enum input = "simulate\n"
        ~ "endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200\n"
        ~ "endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200\n"
        ~ "event msg_1 1700000000 user.created 7b7d\n"
        ~ "event msg_2 1700000100 repo.pushed 7b7d\n"
        ~ "end\n";
    enum expected = "sim 5 3\n"
        ~ "attempt 1 msg_1 ep_a 1 1700000000 failure 500\n"
        ~ "attempt 2 msg_1 ep_b 1 1700000000 success 200\n"
        ~ "attempt 3 msg_1 ep_a 2 1700000005 timeout -\n"
        ~ "attempt 4 msg_2 ep_a 1 1700000100 success 200\n"
        ~ "attempt 5 msg_1 ep_a 3 1700000305 success 200\n"
        ~ "delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94=\n"
        ~ "delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s=\n"
        ~ "delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U=\n";
    assert(processString(input) == expected);
}

@("simulate: retry schedule and failure after 8 attempts")
unittest
{
    auto out_ = processString("simulate\nendpoint e c2VjcmV0 * 500\nevent v 100 t -\nend\n");
    import std.algorithm : canFind;
    assert(out_.canFind("attempt 8 v e 8 99405 failure 500"));
    assert(out_.canFind("attempt 2 v e 2 105 failure 500"));
    assert(out_.canFind("attempt 3 v e 3 405 failure 500"));
    assert(out_.canFind("delivery v e failed 8 99405 "));
}

@("simulate: 410 disables the endpoint for other deliveries")
unittest
{
    auto out_ = processString("simulate\nendpoint e c2VjcmV0 * 410,200\n"
        ~ "event a 0 t -\nevent b 1 t -\nend\n");
    import std.algorithm : canFind;
    assert(out_.canFind("attempt 1 a e 1 0 gone 410"));
    assert(out_.canFind("delivery a e failed 1 0 "));
    assert(out_.canFind("delivery b e disabled 0 - "));
    assert(out_.canFind("sim 1 2\n"));
}

@("simulate: malformed blocks are one error and resynchronise at end")
unittest
{
    assert(processString("simulate\nendpoint e c2VjcmV0 * 200\nbogus\nend\nsha256 -\n")
        == "error\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
    assert(processString("simulate\nendpoint e c2VjcmV0 * 200\n") == "error\n");
    assert(processString("simulate\nend\n") == "error\n");
    assert(processString("simulate\nendpoint e c2VjcmV0 * 200\nevent a 0 t -\nendpoint f c2VjcmV0 * 200\nend\n")
        == "error\n");
    assert(processString("simulate\nendpoint e c2VjcmV0 * 200\nendpoint e c2VjcmV0 * 200\nend\n") == "error\n");
    // `simulate now` does not open a block.
    assert(processString("simulate now\nend\n") == "error\nerror\n");
}

@("simulate: events need not be declared in time order")
unittest
{
    import std.algorithm : canFind;
    auto out_ = processString("simulate\nendpoint e c2VjcmV0 * 200\n"
        ~ "event late 500 t -\nevent early 5 t -\nend\n");
    assert(out_.canFind("attempt 1 early e 1 5 success 200\nattempt 2 late e 1 500 success 200\n"));
}
