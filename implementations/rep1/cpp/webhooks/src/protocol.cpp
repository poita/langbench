#include "webhooks/protocol.hpp"

#include <unordered_set>

#include "webhooks/arguments.hpp"
#include "webhooks/base64.hpp"
#include "webhooks/hex.hpp"
#include "webhooks/hmac.hpp"
#include "webhooks/secret.hpp"
#include "webhooks/sha256.hpp"
#include "webhooks/signature.hpp"
#include "webhooks/simulator.hpp"

namespace webhooks {

namespace {

constexpr std::size_t kMaxEndpoints = 64;
constexpr std::size_t kMaxEvents = 20000;

/// Yields the lines of a buffer split on LF; no empty line after a final LF.
class LineReader {
 public:
  explicit LineReader(std::string_view data) : data_(data) {}

  bool next(std::string_view& line) {
    if (pos_ >= data_.size()) return false;
    std::size_t end = data_.find('\n', pos_);
    if (end == std::string_view::npos) end = data_.size();
    line = data_.substr(pos_, end - pos_);
    pos_ = end + 1;
    return true;
  }

 private:
  std::string_view data_;
  std::size_t pos_ = 0;
};

bool is_blank(std::string_view line) {
  return line.find_first_not_of(' ') == std::string_view::npos;
}

std::string hex_or_dash(ByteView bytes) {
  return bytes.empty() ? std::string("-") : to_hex(bytes);
}

std::vector<SigningKey> make_signing_keys(const std::vector<Bytes>& keys) {
  std::vector<SigningKey> out;
  out.reserve(keys.size());
  for (const Bytes& k : keys) out.emplace_back(k);
  return out;
}

// Each handler returns the output line, or std::nullopt for `error`.
using Fields = std::vector<std::string_view>;
using Reply = std::optional<std::string>;

Reply cmd_sha256(const Fields& f) {
  auto data = parse_hex_argument(f[1]);
  if (!data) return std::nullopt;
  return to_hex(sha256(*data));
}

Reply cmd_hmac(const Fields& f) {
  auto key = parse_hex_argument(f[1]);
  auto msg = parse_hex_argument(f[2]);
  if (!key || !msg) return std::nullopt;
  return to_hex(hmac_sha256(*key, *msg));
}

Reply cmd_b64enc(const Fields& f, bool url_safe) {
  auto data = parse_hex_argument(f[1]);
  if (!data) return std::nullopt;
  std::string s = url_safe ? base64url_encode(*data) : base64_encode(*data);
  return s.empty() ? std::string("-") : s;
}

Reply cmd_b64dec(const Fields& f) {
  auto text = parse_hex_argument(f[1]);
  if (!text) return std::nullopt;
  auto decoded = base64_decode(as_text(*text));
  if (!decoded) return std::nullopt;
  return hex_or_dash(*decoded);
}

Reply cmd_secret(const Fields& f) {
  auto key = parse_secret_argument(f[1]);
  if (!key) return std::nullopt;
  return to_hex(*key);
}

Reply cmd_sign(const Fields& f) {
  auto keys = parse_secrets_argument(f[1]);
  if (!keys || !is_valid_id(f[2]) || !parse_canonical_integer(f[3])) return std::nullopt;
  auto payload = parse_hex_argument(f[4]);
  if (!payload) return std::nullopt;
  return sign_header(make_signing_keys(*keys), f[2], f[3], *payload);
}

Reply cmd_verify(const Fields& f) {
  auto keys = parse_secrets_argument(f[1]);
  if (!keys || !is_valid_id(f[2]) || !is_valid_timestamp_text(f[3])) return std::nullopt;
  auto now = parse_canonical_integer(f[4]);
  auto header = parse_hex_argument(f[5]);
  auto payload = parse_hex_argument(f[6]);
  if (!now || !header || !payload) return std::nullopt;
  VerifyResult r = verify(make_signing_keys(*keys), f[2], f[3], as_text(*header), *payload, *now);
  if (r.ok) return "ok " + std::to_string(r.secret_index) + " " + std::to_string(r.token_index);
  return "fail " + std::string(to_string(r.error));
}

Reply dispatch(const Fields& f) {
  for (std::string_view field : f) {
    if (field.empty()) return std::nullopt;
  }
  const std::string_view name = f[0];
  const std::size_t n = f.size();
  if (name == "sha256" && n == 2) return cmd_sha256(f);
  if (name == "hmac" && n == 3) return cmd_hmac(f);
  if (name == "b64enc" && n == 2) return cmd_b64enc(f, false);
  if (name == "b64urlenc" && n == 2) return cmd_b64enc(f, true);
  if (name == "b64dec" && n == 2) return cmd_b64dec(f);
  if (name == "secret" && n == 2) return cmd_secret(f);
  if (name == "sign" && n == 5) return cmd_sign(f);
  if (name == "verify" && n == 7) return cmd_verify(f);
  return std::nullopt;
}

// ---- simulate blocks -------------------------------------------------------

/// Accumulates and validates the lines of a block.
class BlockParser {
 public:
  /// Feeds one non-blank line other than `end`. Returns false (and the block is
  /// poisoned) on a violation.
  void feed(std::string_view line) {
    if (bad_) return;
    Fields f = split_fields(line);
    for (std::string_view field : f) {
      if (field.empty()) return fail();
    }
    if (f[0] == "endpoint" && f.size() == 5 && !seen_event_) {
      if (!add_endpoint(f)) fail();
    } else if (f[0] == "event" && f.size() == 5) {
      seen_event_ = true;
      if (!add_event(f)) fail();
    } else {
      fail();
    }
  }

  /// Returns the scenario if the block (closed by `end`) is valid.
  bool valid() const { return !bad_ && !scenario_.endpoints.empty(); }
  const Scenario& scenario() const { return scenario_; }

 private:
  void fail() { bad_ = true; }

  bool add_endpoint(const Fields& f) {
    if (scenario_.endpoints.size() >= kMaxEndpoints) return false;
    Endpoint ep;
    if (!is_valid_name(f[1]) || !endpoint_ids_.insert(std::string(f[1])).second) return false;
    ep.id = std::string(f[1]);
    auto keys = parse_secrets_argument(f[2]);
    if (!keys) return false;
    ep.keys = std::move(*keys);
    if (!parse_filter_argument(f[3], ep)) return false;
    auto script = parse_script_argument(f[4]);
    if (!script) return false;
    ep.script = std::move(*script);
    scenario_.endpoints.push_back(std::move(ep));
    return true;
  }

  bool add_event(const Fields& f) {
    if (scenario_.events.size() >= kMaxEvents) return false;
    if (!is_valid_name(f[1]) || !event_ids_.insert(std::string(f[1])).second) return false;
    auto ts = parse_canonical_integer(f[2]);
    if (!ts || !is_valid_name(f[3])) return false;
    auto payload = parse_hex_argument(f[4]);
    if (!payload) return false;
    Event ev;
    ev.id = std::string(f[1]);
    ev.timestamp = *ts;
    ev.type = std::string(f[3]);
    ev.payload = std::move(*payload);
    scenario_.events.push_back(std::move(ev));
    return true;
  }

  Scenario scenario_;
  std::unordered_set<std::string> endpoint_ids_, event_ids_;
  bool seen_event_ = false;
  bool bad_ = false;
};

void format_simulation(const Scenario& sc, const SimulationResult& r, std::string& out) {
  out += "sim " + std::to_string(r.attempts.size()) + " " + std::to_string(r.deliveries.size()) + "\n";
  std::size_t seq = 0;
  for (const AttemptRecord& a : r.attempts) {
    out += "attempt ";
    out += std::to_string(++seq);
    out += ' ';
    out += sc.events[a.event].id;
    out += ' ';
    out += sc.endpoints[a.endpoint].id;
    out += ' ';
    out += std::to_string(a.number);
    out += ' ';
    out += std::to_string(a.time);
    out += ' ';
    out += to_string(a.outcome);
    out += ' ';
    out += a.code ? std::to_string(*a.code) : std::string("-");
    out += '\n';
  }
  for (const DeliveryRecord& d : r.deliveries) {
    out += "delivery ";
    out += sc.events[d.event].id;
    out += ' ';
    out += sc.endpoints[d.endpoint].id;
    out += ' ';
    out += to_string(d.status);
    out += ' ';
    out += std::to_string(d.attempts);
    out += ' ';
    out += d.last_time ? std::to_string(*d.last_time) : std::string("-");
    out += ' ';
    out += d.signature_header;
    out += '\n';
  }
}

void run_block(LineReader& reader, std::string& out) {
  BlockParser parser;
  bool closed = false;
  std::string_view line;
  while (reader.next(line)) {
    if (is_blank(line)) continue;
    if (line == "end") {
      closed = true;
      break;
    }
    parser.feed(line);
  }
  if (!closed || !parser.valid()) {
    out += "error\n";
    return;
  }
  SimulationResult result = simulate(parser.scenario());
  format_simulation(parser.scenario(), result, out);
}

}  // namespace

std::string run_commands(std::string_view input) {
  std::string out;
  LineReader reader(input);
  std::string_view line;
  while (reader.next(line)) {
    if (is_blank(line)) continue;
    if (line == "simulate") {
      run_block(reader, out);
      continue;
    }
    Reply reply = dispatch(split_fields(line));
    if (reply) {
      out += *reply;
    } else {
      out += "error";
    }
    out += '\n';
  }
  return out;
}

}  // namespace webhooks
