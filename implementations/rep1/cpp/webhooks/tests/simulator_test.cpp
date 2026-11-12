#include <gtest/gtest.h>

#include <stdexcept>

#include "webhooks/secret.hpp"
#include "webhooks/simulator.hpp"

using namespace webhooks;

namespace {

Endpoint make_endpoint(std::string id, std::vector<Response> script, bool all = true,
                       std::vector<std::string> types = {}) {
  Endpoint ep;
  ep.id = std::move(id);
  ep.keys = {*parse_secret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")};
  ep.script = std::move(script);
  ep.match_all = all;
  ep.types = std::move(types);
  return ep;
}

Event make_event(std::string id, std::int64_t ts, std::string type = "t") {
  return Event{std::move(id), ts, std::move(type), Bytes{'{', '}'}};
}

}  // namespace

TEST(Simulator, RetryScheduleOfAnAlwaysFailingEndpoint) {
  Scenario sc;
  sc.endpoints.push_back(make_endpoint("a", {Response::status(500)}));
  sc.events.push_back(make_event("e", 1000));
  SimulationResult r = simulate(sc);
  const std::int64_t expected[] = {0, 5, 305, 2105, 9305, 27305, 63305, 99305};
  ASSERT_EQ(r.attempts.size(), 8u);
  for (int i = 0; i < 8; ++i) {
    EXPECT_EQ(r.attempts[i].time, 1000 + expected[i]);
    EXPECT_EQ(r.attempts[i].number, i + 1);
    EXPECT_EQ(r.attempts[i].outcome, Outcome::kFailure);
  }
  ASSERT_EQ(r.deliveries.size(), 1u);
  EXPECT_EQ(r.deliveries[0].status, DeliveryStatus::kFailed);
  EXPECT_EQ(r.deliveries[0].attempts, 8);
  EXPECT_EQ(r.deliveries[0].last_time, 1000 + 99305);
}

TEST(Simulator, ScriptCursorIsPerEndpointAndLastEntryRepeats) {
  Scenario sc;
  sc.endpoints.push_back(make_endpoint("a", {Response::status(500), Response::timed_out(), Response::status(200)}));
  sc.events.push_back(make_event("e1", 100));
  sc.events.push_back(make_event("e2", 101));
  SimulationResult r = simulate(sc);
  // e1@100 500, e2@101 timeout, e1@105 200, e2@106 200
  ASSERT_EQ(r.attempts.size(), 4u);
  EXPECT_EQ(r.attempts[0].outcome, Outcome::kFailure);
  EXPECT_EQ(r.attempts[1].outcome, Outcome::kTimeout);
  EXPECT_FALSE(r.attempts[1].code.has_value());
  EXPECT_EQ(r.attempts[2].outcome, Outcome::kSuccess);
  EXPECT_EQ(r.attempts[3].outcome, Outcome::kSuccess);
  EXPECT_EQ(r.deliveries[0].status, DeliveryStatus::kDelivered);
}

TEST(Simulator, GoneDisablesTheEndpoint) {
  Scenario sc;
  sc.endpoints.push_back(make_endpoint("a", {Response::status(500), Response::status(410)}));
  sc.events.push_back(make_event("e1", 100));
  sc.events.push_back(make_event("e2", 101));
  SimulationResult r = simulate(sc);
  // e1@100 500; e2@101 410 (gone, disabled); e1@105 -> disabled.
  ASSERT_EQ(r.attempts.size(), 2u);
  EXPECT_EQ(r.attempts[1].outcome, Outcome::kGone);
  EXPECT_EQ(r.deliveries[0].status, DeliveryStatus::kDisabled);
  EXPECT_EQ(r.deliveries[0].attempts, 1);
  EXPECT_EQ(r.deliveries[0].last_time, 100);
  EXPECT_EQ(r.deliveries[1].status, DeliveryStatus::kFailed);
}

TEST(Simulator, DisabledBeforeFirstAttemptHasNoLastTime) {
  Scenario sc;
  sc.endpoints.push_back(make_endpoint("a", {Response::status(410)}));
  sc.events.push_back(make_event("e1", 100));
  sc.events.push_back(make_event("e2", 200));
  SimulationResult r = simulate(sc);
  EXPECT_EQ(r.deliveries[1].status, DeliveryStatus::kDisabled);
  EXPECT_EQ(r.deliveries[1].attempts, 0);
  EXPECT_FALSE(r.deliveries[1].last_time.has_value());
}

TEST(Simulator, FiltersAndDeliveryNumbering) {
  Scenario sc;
  sc.endpoints.push_back(make_endpoint("all", {Response::status(200)}));
  sc.endpoints.push_back(make_endpoint("only", {Response::status(200)}, false, {"x", "y"}));
  sc.events.push_back(make_event("e1", 0, "x"));
  sc.events.push_back(make_event("e2", 0, "z"));
  SimulationResult r = simulate(sc);
  ASSERT_EQ(r.deliveries.size(), 3u);
  EXPECT_EQ(r.deliveries[0].endpoint, 0u);
  EXPECT_EQ(r.deliveries[1].endpoint, 1u);
  EXPECT_EQ(r.deliveries[2].event, 1u);
}

TEST(Simulator, EventsNeedNotBeInTimestampOrder) {
  Scenario sc;
  sc.endpoints.push_back(make_endpoint("a", {Response::status(200)}));
  sc.events.push_back(make_event("late", 500));
  sc.events.push_back(make_event("early", 100));
  SimulationResult r = simulate(sc);
  EXPECT_EQ(r.attempts[0].event, 1u);
  EXPECT_EQ(r.attempts[1].event, 0u);
}

TEST(Simulator, HeaderIsTheSignatureOfEveryKey) {
  Scenario sc;
  Endpoint ep = make_endpoint("a", {Response::status(200)});
  ep.keys.push_back(*parse_secret("whsec_c2VjcmV0"));
  sc.endpoints.push_back(ep);
  sc.events.push_back(make_event("msg_1", 1700000000));
  SimulationResult r = simulate(sc);
  EXPECT_EQ(r.deliveries[0].signature_header.size(), 2 * 47 + 1);
  EXPECT_EQ(r.deliveries[0].signature_header.substr(0, 3), "v1,");
}

TEST(Simulator, RejectsEndpointWithoutScript) {
  Scenario sc;
  sc.endpoints.push_back(make_endpoint("a", {}));
  EXPECT_THROW(simulate(sc), std::invalid_argument);
}

TEST(Simulator, NoEventsNoDeliveries) {
  Scenario sc;
  sc.endpoints.push_back(make_endpoint("a", {Response::status(200)}));
  SimulationResult r = simulate(sc);
  EXPECT_TRUE(r.attempts.empty());
  EXPECT_TRUE(r.deliveries.empty());
}
