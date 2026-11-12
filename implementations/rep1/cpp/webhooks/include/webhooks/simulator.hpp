/// @file simulator.hpp
/// Deterministic webhook-delivery simulator with a fixed retry schedule.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "webhooks/bytes.hpp"

namespace webhooks {

/// Delays in seconds before attempt 2, 3, ..., 8 of a delivery.
inline constexpr std::array<std::int64_t, 7> kRetryDelays = {5, 300, 1800, 7200, 18000, 36000, 36000};

/// Maximum number of attempts per delivery (the first plus seven retries).
inline constexpr int kMaxAttempts = 8;

/// One scripted endpoint response: an HTTP status code or a timeout.
struct Response {
  bool timeout = false;
  int code = 0;  ///< HTTP status; meaningless when `timeout`

  static Response status(int code) { return {false, code}; }
  static Response timed_out() { return {true, 0}; }
};

/// A simulated receiving endpoint.
struct Endpoint {
  std::string id;
  std::vector<Bytes> keys;        ///< active raw HMAC keys, in order (at least one)
  bool match_all = true;          ///< filter `*`
  std::vector<std::string> types; ///< accepted event types when !match_all
  std::vector<Response> script;   ///< responses, last one repeats (at least one)

  bool accepts(const std::string& event_type) const;
};

/// An event to be delivered to every matching endpoint.
struct Event {
  std::string id;
  std::int64_t timestamp = 0;  ///< enqueue time, Unix seconds
  std::string type;
  Bytes payload;
};

/// Input of a simulation.
struct Scenario {
  std::vector<Endpoint> endpoints;
  std::vector<Event> events;
};

enum class Outcome { kSuccess, kFailure, kTimeout, kGone };
enum class DeliveryStatus { kDelivered, kFailed, kDisabled };

std::string_view to_string(Outcome outcome) noexcept;
std::string_view to_string(DeliveryStatus status) noexcept;

/// One recorded attempt.
struct AttemptRecord {
  std::size_t event;     ///< index into Scenario::events
  std::size_t endpoint;  ///< index into Scenario::endpoints
  int number;            ///< 1-based attempt number within the delivery
  std::int64_t time;     ///< scheduled time
  Outcome outcome;
  std::optional<int> code;  ///< status code; empty for a timeout
};

/// Final state of one (event, endpoint) delivery.
struct DeliveryRecord {
  std::size_t event;
  std::size_t endpoint;
  DeliveryStatus status;
  int attempts;                        ///< attempts made, 0..8
  std::optional<std::int64_t> last_time;  ///< time of the last attempt made
  std::string signature_header;        ///< `webhook-signature` sent with every attempt
};

/// Result of a simulation.
struct SimulationResult {
  std::vector<AttemptRecord> attempts;      ///< in processing order
  std::vector<DeliveryRecord> deliveries;   ///< in creation order
};

/// Runs the simulation described in SPEC.md §4.
///
/// Deliveries are created for each event (declaration order) and each matching
/// endpoint (declaration order); each is signed once. Attempts are processed in
/// `(scheduled time, delivery number)` order using a binary heap, O((D + A) log D).
///
/// @throws std::invalid_argument if an endpoint has no keys or an empty script.
SimulationResult simulate(const Scenario& scenario);

}  // namespace webhooks
