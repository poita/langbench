"""Deterministic webhook delivery simulator.

Events are signed once per delivery and attempted on a fixed retry schedule
against scripted endpoint responses, driven by a priority queue ordered by
``(scheduled time, delivery number)``.
"""

from __future__ import annotations

import heapq
from collections.abc import Sequence
from dataclasses import dataclass

from .b64 import b64encode
from .signing import compute_mac, signed_content

__all__ = [
    "RETRY_DELAYS",
    "MAX_ATTEMPTS",
    "Endpoint",
    "Event",
    "Attempt",
    "Delivery",
    "SimulationResult",
    "simulate",
]

#: Delay in seconds from attempt *n* to attempt *n+1*.
RETRY_DELAYS = (5, 300, 1800, 7200, 18000, 36000, 36000)
MAX_ATTEMPTS = len(RETRY_DELAYS) + 1


@dataclass(frozen=True)
class Endpoint:
    """A receiving endpoint.

    ``keys`` are raw signing keys; ``event_types`` is ``None`` for "all
    events"; ``script`` lists responses (an HTTP status code, or ``None`` for a
    timeout), the last of which repeats once exhausted.
    """

    id: str
    keys: tuple[bytes, ...]
    event_types: frozenset[str] | None
    script: tuple[int | None, ...]

    def accepts(self, event_type: str) -> bool:
        return self.event_types is None or event_type in self.event_types


@dataclass(frozen=True)
class Event:
    """An event enqueued at ``timestamp`` (Unix seconds)."""

    id: str
    timestamp: int
    type: str
    payload: bytes


@dataclass(frozen=True)
class Attempt:
    seq: int
    event_id: str
    endpoint_id: str
    number: int
    timestamp: int
    outcome: str  # success | failure | timeout | gone
    code: int | None  # None for a timeout

    def __str__(self) -> str:
        code = "-" if self.code is None else str(self.code)
        return (
            f"attempt {self.seq} {self.event_id} {self.endpoint_id} {self.number} "
            f"{self.timestamp} {self.outcome} {code}"
        )


@dataclass
class Delivery:
    number: int
    event_id: str
    endpoint_id: str
    header: str
    status: str = "pending"  # delivered | failed | disabled
    attempts: int = 0
    last_timestamp: int | None = None

    def __str__(self) -> str:
        last = "-" if self.last_timestamp is None else str(self.last_timestamp)
        return (
            f"delivery {self.event_id} {self.endpoint_id} {self.status} "
            f"{self.attempts} {last} {self.header}"
        )


@dataclass(frozen=True)
class SimulationResult:
    attempts: tuple[Attempt, ...]
    deliveries: tuple[Delivery, ...]

    def lines(self) -> list[str]:
        """The output block: header line, attempt lines, delivery lines."""
        out = [f"sim {len(self.attempts)} {len(self.deliveries)}"]
        out.extend(str(a) for a in self.attempts)
        out.extend(str(d) for d in self.deliveries)
        return out


def simulate(endpoints: Sequence[Endpoint], events: Sequence[Event]) -> SimulationResult:
    """Run the delivery simulation and return every attempt and delivery."""
    deliveries: list[Delivery] = []
    delivery_endpoint: list[int] = []
    delivery_start: list[int] = []

    for event in events:
        # Signatures depend only on (key, event); share them between endpoints.
        content = signed_content(event.id, event.timestamp, event.payload)
        sig_cache: dict[bytes, str] = {}
        for ep_index, ep in enumerate(endpoints):
            if not ep.accepts(event.type):
                continue
            parts = []
            for key in ep.keys:
                sig = sig_cache.get(key)
                if sig is None:
                    sig = sig_cache[key] = "v1," + b64encode(compute_mac(key, content))
                parts.append(sig)
            deliveries.append(
                Delivery(len(deliveries), event.id, ep.id, " ".join(parts))
            )
            delivery_endpoint.append(ep_index)
            delivery_start.append(event.timestamp)

    # heap of (scheduled time, delivery number); one pending attempt each
    heap = [(t, n) for n, t in enumerate(delivery_start)]
    heapq.heapify(heap)

    cursors = [0] * len(endpoints)
    disabled = [False] * len(endpoints)
    attempts: list[Attempt] = []

    while heap:
        when, number = heapq.heappop(heap)
        delivery = deliveries[number]
        ep_index = delivery_endpoint[number]
        if disabled[ep_index]:
            delivery.status = "disabled"
            continue

        script = endpoints[ep_index].script
        cursor = cursors[ep_index]
        response = script[cursor] if cursor < len(script) else script[-1]
        cursors[ep_index] = cursor + 1

        delivery.attempts += 1
        delivery.last_timestamp = when
        retryable = False
        if response is None:
            outcome = "timeout"
            retryable = True
        elif 200 <= response <= 299:
            outcome = "success"
            delivery.status = "delivered"
        elif response == 410:
            outcome = "gone"
            delivery.status = "failed"
            disabled[ep_index] = True
        else:
            outcome = "failure"
            retryable = True
        attempts.append(
            Attempt(len(attempts) + 1, delivery.event_id, delivery.endpoint_id,
                    delivery.attempts, when, outcome, response)
        )

        if retryable:
            if delivery.attempts >= MAX_ATTEMPTS:
                delivery.status = "failed"
            else:
                heapq.heappush(heap, (when + RETRY_DELAYS[delivery.attempts - 1], number))

    return SimulationResult(tuple(attempts), tuple(deliveries))
