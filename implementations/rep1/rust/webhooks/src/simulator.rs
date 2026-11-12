//! Deterministic webhook delivery simulator.
//!
//! Events are matched against endpoints to create *deliveries*; each delivery
//! is signed once and then attempted on a fixed retry schedule against a
//! scripted endpoint, using a priority queue ordered by
//! `(scheduled time, delivery number)`.
//!
//! ```
//! use webhooks::{simulate, Endpoint, Event, Filter, Response, Secret};
//!
//! let endpoints = vec![Endpoint {
//!     id: "ep".into(),
//!     secrets: vec![Secret::parse("c2VjcmV0").unwrap()],
//!     filter: Filter::All,
//!     script: vec![Response::Status(500), Response::Status(200)],
//! }];
//! let events = vec![Event { id: "ev".into(), ts: 100, kind: "t".into(), payload: vec![] }];
//! let report = simulate(&endpoints, &events);
//! assert_eq!(report.attempts.len(), 2);
//! assert_eq!(report.attempts[1].ts, 105);
//! ```

use crate::secret::Secret;
use crate::signature::sign_header;
use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::fmt::Write;

/// Maximum number of attempts per delivery.
pub const MAX_ATTEMPTS: u32 = 8;

/// Delay in seconds after attempt *n* (1-based) before attempt *n+1*.
pub const RETRY_DELAYS: [i64; 7] = [5, 300, 1800, 7200, 18000, 36000, 36000];

/// One scripted endpoint response.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Response {
    /// An HTTP status code (`100..=599`).
    Status(u16),
    /// The request times out.
    Timeout,
}

/// Which events an endpoint receives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Filter {
    /// Every event.
    All,
    /// Events whose type equals one of these.
    Types(Vec<String>),
}

impl Filter {
    /// Whether an event of type `kind` is delivered.
    pub fn matches(&self, kind: &str) -> bool {
        match self {
            Filter::All => true,
            Filter::Types(t) => t.iter().any(|x| x == kind),
        }
    }
}

/// A simulated receiving endpoint.
#[derive(Clone, Debug)]
pub struct Endpoint {
    /// Endpoint identifier.
    pub id: String,
    /// Active signing secrets, in order. Must not be empty for useful output.
    pub secrets: Vec<Secret>,
    /// Event filter.
    pub filter: Filter,
    /// Responses returned to successive attempts; the last repeats forever.
    /// Must not be empty.
    pub script: Vec<Response>,
}

/// An event to deliver.
#[derive(Clone, Debug)]
pub struct Event {
    /// Event (message) identifier.
    pub id: String,
    /// Time the event is enqueued, Unix seconds.
    pub ts: i64,
    /// Event type.
    pub kind: String,
    /// Request body.
    pub payload: Vec<u8>,
}

/// Result of one attempt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// 2xx response.
    Success,
    /// Retryable failure (non-2xx, non-410 status).
    Failure,
    /// Timeout.
    Timeout,
    /// 410 response; the endpoint is disabled.
    Gone,
}

impl Outcome {
    /// Name used in the output format.
    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Success => "success",
            Outcome::Failure => "failure",
            Outcome::Timeout => "timeout",
            Outcome::Gone => "gone",
        }
    }
}

/// Final state of a delivery.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryStatus {
    /// A 2xx response was received.
    Delivered,
    /// Retries were exhausted or the endpoint answered 410.
    Failed,
    /// The endpoint was disabled before the delivery finished.
    Disabled,
}

impl DeliveryStatus {
    /// Name used in the output format.
    pub fn as_str(self) -> &'static str {
        match self {
            DeliveryStatus::Delivered => "delivered",
            DeliveryStatus::Failed => "failed",
            DeliveryStatus::Disabled => "disabled",
        }
    }
}

/// One recorded attempt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Attempt {
    /// Delivery number (index into [`Report::deliveries`]).
    pub delivery: usize,
    /// 1-based attempt number within the delivery.
    pub n: u32,
    /// Scheduled time.
    pub ts: i64,
    /// Outcome.
    pub outcome: Outcome,
    /// Status code, or `None` for a timeout.
    pub code: Option<u16>,
}

/// A delivery of one event to one endpoint.
#[derive(Clone, Debug)]
pub struct Delivery {
    /// Index of the event in the input slice.
    pub event: usize,
    /// Index of the endpoint in the input slice.
    pub endpoint: usize,
    /// Final status.
    pub status: DeliveryStatus,
    /// Number of attempts made.
    pub attempts: u32,
    /// Scheduled time of the last attempt made.
    pub last_ts: Option<i64>,
    /// The `webhook-signature` header value.
    pub header: String,
}

/// The outcome of a simulation.
#[derive(Debug)]
pub struct Report<'a> {
    endpoints: &'a [Endpoint],
    events: &'a [Event],
    /// Attempts in processing order.
    pub attempts: Vec<Attempt>,
    /// Deliveries in delivery-number order.
    pub deliveries: Vec<Delivery>,
}

impl Report<'_> {
    /// Renders the report in the `sim` block output format (without a
    /// trailing newline).
    pub fn render(&self) -> String {
        let mut out = String::with_capacity(64 * (self.attempts.len() + self.deliveries.len()) + 16);
        let _ = write!(out, "sim {} {}", self.attempts.len(), self.deliveries.len());
        for (i, a) in self.attempts.iter().enumerate() {
            let d = &self.deliveries[a.delivery];
            let _ = write!(
                out,
                "\nattempt {} {} {} {} {} {} ",
                i + 1,
                self.events[d.event].id,
                self.endpoints[d.endpoint].id,
                a.n,
                a.ts,
                a.outcome.as_str()
            );
            match a.code {
                Some(c) => {
                    let _ = write!(out, "{c}");
                }
                None => out.push('-'),
            }
        }
        for d in &self.deliveries {
            let _ = write!(
                out,
                "\ndelivery {} {} {} {} ",
                self.events[d.event].id,
                self.endpoints[d.endpoint].id,
                d.status.as_str(),
                d.attempts
            );
            match d.last_ts {
                Some(t) => {
                    let _ = write!(out, "{t}");
                }
                None => out.push('-'),
            }
            out.push(' ');
            out.push_str(&d.header);
        }
        out
    }
}

/// Runs the simulation.
///
/// Deliveries are created per event (in order) per matching endpoint (in
/// order), signed once, and attempted according to the retry schedule.
///
/// # Panics
///
/// Panics if an endpoint's `script` is empty.
pub fn simulate<'a>(endpoints: &'a [Endpoint], events: &'a [Event]) -> Report<'a> {
    let mut deliveries: Vec<Delivery> = Vec::new();
    for (ei, ev) in events.iter().enumerate() {
        for (pi, ep) in endpoints.iter().enumerate() {
            if ep.filter.matches(&ev.kind) {
                deliveries.push(Delivery {
                    event: ei,
                    endpoint: pi,
                    status: DeliveryStatus::Failed,
                    attempts: 0,
                    last_ts: None,
                    header: sign_header(&ep.secrets, &ev.id, &ev.ts.to_string(), &ev.payload),
                });
            }
        }
    }

    let mut heap: BinaryHeap<Reverse<(i64, usize)>> = deliveries
        .iter()
        .enumerate()
        .map(|(n, d)| Reverse((events[d.event].ts, n)))
        .collect();
    let mut cursors = vec![0usize; endpoints.len()];
    let mut disabled = vec![false; endpoints.len()];
    let mut attempts = Vec::new();

    while let Some(Reverse((ts, n))) = heap.pop() {
        let d = &mut deliveries[n];
        let ep = d.endpoint;
        if disabled[ep] {
            d.status = DeliveryStatus::Disabled;
            continue;
        }
        let script = &endpoints[ep].script;
        let response = script[cursors[ep].min(script.len() - 1)];
        cursors[ep] += 1;
        d.attempts += 1;
        d.last_ts = Some(ts);
        let (outcome, code) = match response {
            Response::Status(c @ 200..=299) => (Outcome::Success, Some(c)),
            Response::Status(410) => (Outcome::Gone, Some(410)),
            Response::Status(c) => (Outcome::Failure, Some(c)),
            Response::Timeout => (Outcome::Timeout, None),
        };
        attempts.push(Attempt { delivery: n, n: d.attempts, ts, outcome, code });
        match outcome {
            Outcome::Success => d.status = DeliveryStatus::Delivered,
            Outcome::Gone => {
                d.status = DeliveryStatus::Failed;
                disabled[ep] = true;
            }
            Outcome::Failure | Outcome::Timeout => {
                if d.attempts >= MAX_ATTEMPTS {
                    d.status = DeliveryStatus::Failed;
                } else {
                    heap.push(Reverse((ts + RETRY_DELAYS[d.attempts as usize - 1], n)));
                }
            }
        }
    }
    Report { endpoints, events, attempts, deliveries }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ep(id: &str, filter: Filter, script: Vec<Response>) -> Endpoint {
        Endpoint { id: id.into(), secrets: vec![Secret::parse("c2VjcmV0").unwrap()], filter, script }
    }

    fn ev(id: &str, ts: i64, kind: &str) -> Event {
        Event { id: id.into(), ts, kind: kind.into(), payload: b"{}".to_vec() }
    }

    #[test]
    fn exhausts_after_eight_attempts() {
        let eps = [ep("a", Filter::All, vec![Response::Status(500)])];
        let evs = [ev("e", 0, "t")];
        let r = simulate(&eps, &evs);
        let times: Vec<i64> = r.attempts.iter().map(|a| a.ts).collect();
        assert_eq!(times, vec![0, 5, 305, 2105, 9305, 27305, 63305, 99305]);
        assert_eq!(r.deliveries[0].status, DeliveryStatus::Failed);
        assert_eq!(r.deliveries[0].attempts, 8);
    }

    #[test]
    fn gone_disables_endpoint_for_other_deliveries() {
        let eps = [ep("a", Filter::All, vec![Response::Status(500), Response::Status(410)])];
        let evs = [ev("e1", 0, "t"), ev("e2", 1, "t")];
        let r = simulate(&eps, &evs);
        // e1@0 fails (500), e2@1 gets 410 -> disabled, e1 retry @5 is disabled.
        assert_eq!(r.attempts.len(), 2);
        assert_eq!(r.deliveries[0].status, DeliveryStatus::Disabled);
        assert_eq!(r.deliveries[0].attempts, 1);
        assert_eq!(r.deliveries[1].status, DeliveryStatus::Failed);
    }

    #[test]
    fn disabled_without_attempts_has_dash() {
        let eps = [ep("a", Filter::All, vec![Response::Status(410)])];
        let evs = [ev("e1", 0, "t"), ev("e2", 0, "t")];
        let out = simulate(&eps, &evs).render();
        let line = out.lines().find(|l| l.starts_with("delivery e2")).unwrap();
        assert!(line.starts_with("delivery e2 a disabled 0 - v1,"));
    }

    #[test]
    fn earlier_timestamp_runs_first_and_ties_by_delivery() {
        let eps = [ep("a", Filter::All, vec![Response::Status(200)])];
        let evs = [ev("late", 10, "t"), ev("early", 5, "t"), ev("tie", 10, "t")];
        let r = simulate(&eps, &evs);
        let order: Vec<usize> = r.attempts.iter().map(|a| a.delivery).collect();
        assert_eq!(order, vec![1, 0, 2]);
    }

    #[test]
    fn filters() {
        let eps = [
            ep("a", Filter::Types(vec!["x".into(), "y".into()]), vec![Response::Timeout]),
            ep("b", Filter::All, vec![Response::Status(200)]),
        ];
        let evs = [ev("e1", 0, "y"), ev("e2", 0, "z")];
        let r = simulate(&eps, &evs);
        assert_eq!(r.deliveries.len(), 3);
        assert_eq!(r.attempts[0].code, None);
    }
}
