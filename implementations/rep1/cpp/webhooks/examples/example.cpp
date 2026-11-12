// Signs a webhook, verifies it, and runs a small delivery simulation.
#include <iostream>

#include "webhooks/webhooks.hpp"

int main() {
  using namespace webhooks;

  Bytes key = *parse_secret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw");
  std::vector<SigningKey> keys;
  keys.emplace_back(key);

  std::string_view body = R"({"test": 2432232314})";
  std::string header = sign_header(keys, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", as_bytes(body));
  std::cout << header << "\n";  // v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=

  VerifyResult r = verify(keys, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", header,
                          as_bytes(body), 1614265400);
  std::cout << (r.ok ? "verified" : std::string(to_string(r.error))) << "\n";

  Scenario scenario;
  Endpoint ep;
  ep.id = "ep_a";
  ep.keys = {key};
  ep.script = {Response::status(500), Response::timed_out(), Response::status(200)};
  scenario.endpoints.push_back(ep);
  scenario.events.push_back({"msg_1", 1700000000, "user.created", Bytes{'{', '}'}});
  SimulationResult sim = simulate(scenario);
  for (const AttemptRecord& a : sim.attempts) {
    std::cout << "attempt " << a.number << " at " << a.time << ": " << to_string(a.outcome) << "\n";
  }
}
