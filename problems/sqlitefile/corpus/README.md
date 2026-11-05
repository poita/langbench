# Vendored corpora

* `chinook/chinook.sqlite.gz` — the Chinook sample database
  (https://github.com/lerocha/chinook-database, `Chinook_Sqlite.sqlite`),
  gzip-compressed verbatim. MIT licence, see `chinook/LICENSE.md`.
* `ourairports/airports.csv.gz`, `ourairports/runways.csv.gz` — OurAirports
  open data (https://ourairports.com/data/), column-trimmed and
  gzip-compressed. Public domain, see `ourairports/LICENSE.txt`.

`gen_tests.py` reads these files and writes the `.sqlite` databases in
`tests/*/input/`.  Loading the OurAirports data rounds `latitude_deg` and
`longitude_deg` to six decimal places (about 0.1 m); the source values carry
float32 conversion noise out to 17 significant digits, and the problem
guarantees every stored REAL round-trips through 15 significant digits.
