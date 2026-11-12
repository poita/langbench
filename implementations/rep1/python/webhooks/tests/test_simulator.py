from webhooks import Endpoint, Event, parse_secret, simulate

KEY = parse_secret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")


def ep(i, script, types=None, keys=(KEY,)):
    return Endpoint(i, tuple(keys), None if types is None else frozenset(types), tuple(script))


def ev(i, ts, typ="t", payload=b"{}"):
    return Event(i, ts, typ, payload)


def test_full_retry_schedule_and_failure():
    r = simulate([ep("a", [500])], [ev("e", 100)])
    assert [a.timestamp for a in r.attempts] == [
        100, 105, 405, 2205, 9405, 27405, 63405, 99405,
    ]
    d = r.deliveries[0]
    assert (d.status, d.attempts, d.last_timestamp) == ("failed", 8, 99405)


def test_timeout_and_script_exhaustion():
    r = simulate([ep("a", [None, 500, 200])], [ev("e", 0)])
    assert [(a.outcome, a.code) for a in r.attempts] == [
        ("timeout", None), ("failure", 500), ("success", 200),
    ]
    assert r.deliveries[0].status == "delivered"


def test_gone_disables_endpoint():
    r = simulate([ep("a", [410, 200])], [ev("e1", 0), ev("e2", 1)])
    assert [(a.event_id, a.endpoint_id) for a in r.attempts] == [("e1", "a")]
    assert [d.status for d in r.deliveries] == ["failed", "disabled"]
    assert r.deliveries[1].attempts == 0 and r.deliveries[1].last_timestamp is None


def test_disabled_after_retries():
    r = simulate([ep("a", [500, 410, 200])], [ev("e1", 0), ev("e2", 1)])
    # e1@0 fails, e2@1 gone -> e1's retry at 5 sees disabled
    assert [d.status for d in r.deliveries] == ["disabled", "failed"]
    assert r.deliveries[0].attempts == 1


def test_filters_and_creation_order():
    r = simulate([ep("a", [200], {"x"}), ep("b", [200])], [ev("e1", 5, "x"), ev("e2", 1, "y")])
    assert [(d.event_id, d.endpoint_id) for d in r.deliveries] == [
        ("e1", "a"), ("e1", "b"), ("e2", "b"),
    ]
    assert [a.event_id for a in r.attempts] == ["e2", "e1", "e1"]


def test_spec_example_output():
    secrets = [parse_secret("whsec_c2VjcmV0"), parse_secret("whsec_b3RoZXI")]
    r = simulate(
        [ep("ep_a", [500, None, 200]), ep("ep_b", [200], {"user.created"}, secrets)],
        [ev("msg_1", 1700000000, "user.created"), ev("msg_2", 1700000100, "repo.pushed")],
    )
    assert r.lines()[0] == "sim 5 3"
    assert r.lines()[-2] == (
        "delivery msg_1 ep_b delivered 1 1700000000 "
        "v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= "
        "v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s="
    )
