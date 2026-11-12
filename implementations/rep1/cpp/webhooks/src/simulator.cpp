#include "webhooks/simulator.hpp"

#include <algorithm>
#include <functional>
#include <queue>
#include <stdexcept>
#include <utility>

#include "webhooks/signature.hpp"

namespace webhooks {

bool Endpoint::accepts(const std::string& event_type) const {
  if (match_all) return true;
  return std::find(types.begin(), types.end(), event_type) != types.end();
}

std::string_view to_string(Outcome outcome) noexcept {
  switch (outcome) {
    case Outcome::kSuccess: return "success";
    case Outcome::kFailure: return "failure";
    case Outcome::kTimeout: return "timeout";
    case Outcome::kGone: return "gone";
  }
  return "failure";
}

std::string_view to_string(DeliveryStatus status) noexcept {
  switch (status) {
    case DeliveryStatus::kDelivered: return "delivered";
    case DeliveryStatus::kFailed: return "failed";
    case DeliveryStatus::kDisabled: return "disabled";
  }
  return "failed";
}

namespace {

struct EndpointState {
  std::vector<SigningKey> keys;
  std::size_t cursor = 0;
  bool disabled = false;
};

struct DeliveryState {
  int next_attempt = 1;  // number of the pending attempt
};

using QueueEntry = std::pair<std::int64_t, std::size_t>;  // (time, delivery number)

}  // namespace

SimulationResult simulate(const Scenario& scenario) {
  const auto& endpoints = scenario.endpoints;
  const auto& events = scenario.events;

  std::vector<EndpointState> ep_state(endpoints.size());
  for (std::size_t p = 0; p < endpoints.size(); ++p) {
    if (endpoints[p].keys.empty() || endpoints[p].script.empty()) {
      throw std::invalid_argument("endpoint '" + endpoints[p].id + "' needs keys and a script");
    }
    for (const Bytes& k : endpoints[p].keys) ep_state[p].keys.emplace_back(k);
  }

  SimulationResult result;
  std::vector<DeliveryState> state;
  std::priority_queue<QueueEntry, std::vector<QueueEntry>, std::greater<QueueEntry>> queue;

  // Create deliveries, signing each exactly once.
  for (std::size_t e = 0; e < events.size(); ++e) {
    const Event& ev = events[e];
    const std::string ts_text = std::to_string(ev.timestamp);
    for (std::size_t p = 0; p < endpoints.size(); ++p) {
      if (!endpoints[p].accepts(ev.type)) continue;
      DeliveryRecord d;
      d.event = e;
      d.endpoint = p;
      d.status = DeliveryStatus::kFailed;
      d.attempts = 0;
      d.signature_header = sign_header(ep_state[p].keys, ev.id, ts_text, ev.payload);
      queue.emplace(ev.timestamp, result.deliveries.size());
      result.deliveries.push_back(std::move(d));
      state.push_back({});
    }
  }

  while (!queue.empty()) {
    auto [time, di] = queue.top();
    queue.pop();
    DeliveryRecord& d = result.deliveries[di];
    EndpointState& ep = ep_state[d.endpoint];
    const Endpoint& spec = endpoints[d.endpoint];

    if (ep.disabled) {
      d.status = DeliveryStatus::kDisabled;
      continue;
    }

    const Response& resp = spec.script[std::min(ep.cursor, spec.script.size() - 1)];
    ++ep.cursor;

    AttemptRecord a;
    a.event = d.event;
    a.endpoint = d.endpoint;
    a.number = state[di].next_attempt;
    a.time = time;
    bool retryable = false;
    if (resp.timeout) {
      a.outcome = Outcome::kTimeout;
      retryable = true;
    } else {
      a.code = resp.code;
      if (resp.code >= 200 && resp.code <= 299) {
        a.outcome = Outcome::kSuccess;
        d.status = DeliveryStatus::kDelivered;
      } else if (resp.code == 410) {
        a.outcome = Outcome::kGone;
        d.status = DeliveryStatus::kFailed;
        ep.disabled = true;
      } else {
        a.outcome = Outcome::kFailure;
        retryable = true;
      }
    }
    result.attempts.push_back(a);
    d.attempts = a.number;
    d.last_time = time;

    if (retryable) {
      if (a.number >= kMaxAttempts) {
        d.status = DeliveryStatus::kFailed;
      } else {
        state[di].next_attempt = a.number + 1;
        queue.emplace(time + kRetryDelays[a.number - 1], di);
      }
    }
  }
  return result;
}

}  // namespace webhooks
