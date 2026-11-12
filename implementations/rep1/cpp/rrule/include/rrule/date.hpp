// Calendar arithmetic for the proleptic Gregorian calendar.
//
// Dates are represented either as a (year, month, day) triple (`Date`) or as
// a "day number": the count of days since 0001-01-01, which is day 0 and a
// Monday. All conversions are closed-form (O(1)); nothing iterates over years
// or months.
#pragma once

#include <cstdint>
#include <string>

namespace rrule {

/// Weekday numbering used throughout the library: Monday = 0 ... Sunday = 6.
enum class Weekday : int {
  Monday = 0, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday
};

/// A calendar date.
struct Date {
  int year = 1;
  int month = 1;  ///< 1..12
  int day = 1;    ///< 1..days_in_month(year, month)

  friend bool operator==(const Date& a, const Date& b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
};

/// A floating (zone-less) date-time with second resolution.
struct DateTime {
  Date date;
  int hour = 0;
  int minute = 0;
  int second = 0;

  friend bool operator==(const DateTime& a, const DateTime& b) {
    return a.date == b.date && a.hour == b.hour && a.minute == b.minute &&
           a.second == b.second;
  }
  friend bool operator!=(const DateTime& a, const DateTime& b) { return !(a == b); }
};

constexpr int kSecondsPerDay = 86400;

/// True if `year` is a Gregorian leap year.
constexpr bool is_leap_year(int year) {
  return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

/// Number of days in the given month (1..12) of `year`.
constexpr int days_in_month(int year, int month) {
  constexpr int kDays[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  return kDays[month - 1] + (month == 2 && is_leap_year(year) ? 1 : 0);
}

/// Number of days in `year` (365 or 366).
constexpr int days_in_year(int year) { return is_leap_year(year) ? 366 : 365; }

/// Day number (days since 0001-01-01) of a calendar date. year >= 1.
std::int64_t days_from_civil(int year, int month, int day);
inline std::int64_t days_from_civil(const Date& d) {
  return days_from_civil(d.year, d.month, d.day);
}

/// Inverse of days_from_civil. `day_number` >= 0.
Date civil_from_days(std::int64_t day_number);

/// Weekday of a day number (day 0 is a Monday).
constexpr Weekday weekday_of_day(std::int64_t day_number) {
  return static_cast<Weekday>(day_number % 7);
}

/// Weekday of a date.
Weekday weekday_of(const Date& d);

/// Seconds since 00:00:00 of the day: hour * 3600 + minute * 60 + second.
constexpr int seconds_of_day(const DateTime& t) {
  return t.hour * 3600 + t.minute * 60 + t.second;
}

/// Seconds since 0001-01-01T00:00:00; a total order key for date-times.
std::int64_t to_seconds(const DateTime& t);

/// Formats as `YYYYMMDDTHHMMSS`.
std::string format_datetime(const DateTime& t);

}  // namespace rrule
