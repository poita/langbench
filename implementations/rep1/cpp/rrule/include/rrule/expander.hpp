// Recurrence expansion.
#pragma once

#include <cstddef>
#include <vector>

#include "rrule/date.hpp"
#include "rrule/rule.hpp"

namespace rrule {

/// Last year for which periods are enumerated.
constexpr int kMaxYear = 9999;

/// Expands `rule` starting at `dtstart` and returns at most `limit`
/// occurrences, in chronological order. COUNT and UNTIL of the rule are
/// honoured in addition to `limit`.
///
/// The rule is evaluated period by period (see SPEC.md): every period of the
/// frequency is enumerated, each of its candidate days is tested against every
/// filter, BYSETPOS selects among the kept days, and occurrences earlier than
/// `dtstart` are skipped. Enumeration stops at the limit, at COUNT, after
/// UNTIL, or when the next period would start after year 9999.
///
/// The rule need not have its defaults applied; `expand` applies
/// `with_defaults` itself. Cost is O(periods + candidate days + occurrences).
std::vector<DateTime> expand(const DateTime& dtstart, const Rule& rule,
                             std::size_t limit);

}  // namespace rrule
