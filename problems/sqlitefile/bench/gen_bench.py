#!/usr/bin/env python3
"""Regenerate problems/sqlitefile/bench/ (performance benchmark inputs).

Writes three directory-mode cases in the same layout as tests/
(NNN_name/input/{<db>.sqlite,queries.txt} and NNN_name/expected/NNN.txt):

  001_airports_scan    full-table scans, filters and sorts over the 16 MB
                       OurAirports database (few queries, lots of rows each)
  002_index_lookups    999 INDEX lookups (unique and multi-row keys) against
                       a 1024-byte-page database with six indexes
  003_chinook_mixed    999 mixed small queries (FK index lookups, filtered
                       selects, sorts, counts, schema) against Chinook

Everything is deterministic (fixed seeds, vendored corpora).  Expected outputs
come from the Python reference implementation and every query is cross-checked
against the sqlite3 command line shell (skip that with --no-oracle).

Run:  python3 problems/sqlitefile/bench/gen_bench.py
"""
import argparse
import os
import random
import shutil
import sqlite3
import subprocess
import sys
import tempfile

BENCH = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(BENCH)
sys.dont_write_bytecode = True  # keep gen_tests.py from leaving __pycache__ behind
sys.path.insert(0, PROBLEM)
import gen_tests as G  # noqa: E402


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def lit(v):
    """Render a Python value as a query-language literal."""
    if v is None:
        return "NULL"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    return "'" + v.replace("'", "''") + "'"


def column(db, sql):
    con = sqlite3.connect(db)
    try:
        return [r[0] for r in con.execute(sql)]
    finally:
        con.close()


# ---------------------------------------------------------------------------
# 001: scan throughput over the full OurAirports database
# ---------------------------------------------------------------------------


def db_airports_scan():
    """The full OurAirports import from gen_tests.py without its indexes, which
    a scan workload never reads (keeps bench/ small)."""
    path = G.db_airports()
    con = sqlite3.connect(path)
    for (name,) in con.execute("SELECT name FROM sqlite_schema WHERE type='index' "
                               "AND sql IS NOT NULL").fetchall():
        con.execute("DROP INDEX %s" % name)
    con.commit()
    con.execute("VACUUM")
    con.close()
    return path


def queries_airports_scan(db):
    return [
        "COUNT airport",
        "COUNT runway",
        "SELECT ident,name,elevation_ft FROM airport WHERE elevation_ft > 12000 "
        "ORDER BY elevation_ft DESC LIMIT 50",
        "SELECT ident,name,municipality FROM airport WHERE iso_country = 'BR' "
        "AND type = 'medium_airport' ORDER BY name",
        "SELECT ident,iata_code,name FROM airport WHERE type = 'large_airport' "
        "ORDER BY iata_code LIMIT 100",
        "SELECT ident,latitude_deg,longitude_deg FROM airport WHERE latitude_deg > 66.5 "
        "ORDER BY latitude_deg DESC LIMIT 40",
        "SELECT ident,name FROM airport WHERE scheduled_service = 'yes' "
        "AND continent = 'OC' ORDER BY name LIMIT 60",
        "SELECT id,airport_ident,length_ft,width_ft FROM runway WHERE surface = 'ASP' "
        "AND length_ft >= 11000 ORDER BY length_ft DESC LIMIT 50",
        "SELECT airport_ident,le_ident,he_ident,length_ft FROM runway WHERE lighted = 1 "
        "AND closed = 0 AND length_ft > 13000",
        "SELECT * FROM airport WHERE iso_region = 'AU-NSW' AND type = 'small_airport' "
        "ORDER BY municipality LIMIT 30",
        "SELECT ident,name,iso_country FROM airport WHERE municipality = 'London'",
        "SELECT ident,name,elevation_ft FROM airport WHERE elevation_ft < -50 "
        "ORDER BY elevation_ft",
        "SELECT * FROM runway ORDER BY width_ft DESC LIMIT 20",
        "SELECT ident,name FROM airport ORDER BY name LIMIT 25",
        "SELECT ident,name FROM airport ORDER BY name DESC LIMIT 25",
        "SELECT ident,gps_code,name FROM airport WHERE gps_code IS NOT NULL "
        "AND iso_country = 'CA' ORDER BY gps_code LIMIT 40",
        "SELECT rowid,ident,longitude_deg FROM airport WHERE longitude_deg >= 170 "
        "AND latitude_deg < -30 ORDER BY longitude_deg",
        "SELECT id,airport_ref,airport_ident FROM runway WHERE surface IS NULL "
        "AND closed = 1 LIMIT 100",
        "SELECT id,ident,type,name,elevation_ft FROM airport WHERE iso_country = 'IS'",
        "SELECT ident,type,municipality FROM airport WHERE iso_country = 'NZ' "
        "AND type != 'heliport' ORDER BY municipality DESC",
        "SELECT * FROM airport WHERE iata_code IS NOT NULL AND elevation_ft >= 9000 "
        "ORDER BY elevation_ft DESC",
        "SELECT airport_ident,length_ft,surface FROM runway WHERE length_ft >= 5000 "
        "AND length_ft <= 5010 AND width_ft = 100 ORDER BY airport_ident",
    ]


def queries_airports_scan_long(db, n=999):
    """The long tier: n scans drawn from the same report shapes as
    queries_airports_scan, with seeded parameters (countries, regions,
    thresholds, surfaces) instead of fixed ones. Every fifth query is one of
    the whole-table sorts (ORDER BY name / width_ft), the most expensive
    reports, since the 999-query cap bounds the query count."""
    rnd = random.Random(20261031)
    countries = column(db, "SELECT iso_country FROM airport GROUP BY iso_country "
                           "HAVING count(*) BETWEEN 30 AND 3000 ORDER BY 1")
    regions = column(db, "SELECT iso_region FROM airport GROUP BY iso_region "
                         "HAVING count(*) BETWEEN 30 AND 1500 ORDER BY 1")
    cities = column(db, "SELECT municipality FROM airport WHERE municipality IS NOT NULL "
                        "GROUP BY municipality HAVING count(*) BETWEEN 3 AND 60 ORDER BY 1")
    surfaces = column(db, "SELECT surface FROM runway WHERE surface IS NOT NULL GROUP BY surface "
                          "HAVING count(*) >= 200 ORDER BY 1")
    types = ["small_airport", "medium_airport", "large_airport", "heliport", "seaplane_base",
             "closed"]
    continents = ["AF", "AS", "EU", "NA", "OC", "SA"]

    def c():
        return lit(rnd.choice(countries))

    templates = [
        lambda: "COUNT airport",
        lambda: "COUNT runway",
        lambda: "SELECT ident,name,elevation_ft FROM airport WHERE elevation_ft > %d "
                "ORDER BY elevation_ft DESC LIMIT 50" % rnd.randrange(6000, 14000),
        lambda: "SELECT ident,name,municipality FROM airport WHERE iso_country = %s "
                "AND type = %s ORDER BY name" % (c(), lit(rnd.choice(types[1:3]))),
        lambda: "SELECT ident,iata_code,name FROM airport WHERE type = %s "
                "ORDER BY iata_code LIMIT 100" % lit(rnd.choice(types)),
        lambda: "SELECT ident,latitude_deg,longitude_deg FROM airport WHERE latitude_deg > %s "
                "ORDER BY latitude_deg DESC LIMIT 40" % repr(rnd.randrange(300, 800) / 10),
        lambda: "SELECT ident,name FROM airport WHERE scheduled_service = 'yes' "
                "AND continent = %s ORDER BY name LIMIT 60" % lit(rnd.choice(continents)),
        lambda: "SELECT id,airport_ident,length_ft,width_ft FROM runway WHERE surface = %s "
                "AND length_ft >= %d ORDER BY length_ft DESC LIMIT 50"
                % (lit(rnd.choice(surfaces)), rnd.randrange(3000, 12000)),
        lambda: "SELECT airport_ident,le_ident,he_ident,length_ft FROM runway WHERE lighted = 1 "
                "AND closed = 0 AND length_ft > %d" % rnd.randrange(12000, 15000),
        lambda: "SELECT * FROM airport WHERE iso_region = %s AND type = %s "
                "ORDER BY municipality LIMIT 30" % (lit(rnd.choice(regions)), lit(rnd.choice(types[:3]))),
        lambda: "SELECT ident,name,iso_country FROM airport WHERE municipality = %s"
                % lit(rnd.choice(cities)),
        lambda: "SELECT ident,name,elevation_ft FROM airport WHERE elevation_ft < %d "
                "ORDER BY elevation_ft" % rnd.randrange(-200, -20),
        lambda: "SELECT * FROM runway ORDER BY width_ft DESC LIMIT 20",
        lambda: "SELECT ident,name FROM airport ORDER BY name LIMIT 25",
        lambda: "SELECT ident,name FROM airport ORDER BY name DESC LIMIT 25",
        lambda: "SELECT ident,gps_code,name FROM airport WHERE gps_code IS NOT NULL "
                "AND iso_country = %s ORDER BY gps_code LIMIT 40" % c(),
        lambda: "SELECT rowid,ident,longitude_deg FROM airport WHERE longitude_deg >= %d "
                "AND latitude_deg < %d ORDER BY longitude_deg"
                % (rnd.randrange(160, 178), rnd.randrange(-50, -25)),
        lambda: "SELECT id,airport_ref,airport_ident FROM runway WHERE surface IS NULL "
                "AND closed = %d LIMIT 100" % rnd.randrange(2),
        lambda: "SELECT id,ident,type,name,elevation_ft FROM airport WHERE iso_country = %s "
                "AND type = %s" % (c(), lit(rnd.choice(types[:3]))),
        lambda: "SELECT ident,type,municipality FROM airport WHERE iso_region = %s "
                "AND type != 'heliport' ORDER BY municipality DESC" % lit(rnd.choice(regions)),
        lambda: "SELECT * FROM airport WHERE iata_code IS NOT NULL AND elevation_ft >= %d "
                "ORDER BY elevation_ft DESC" % rnd.randrange(8000, 11000),
        lambda: "SELECT airport_ident,length_ft,surface FROM runway WHERE length_ft >= %d "
                "AND length_ft <= %d AND width_ft = %d ORDER BY airport_ident"
                % ((lambda a: (a, a + 10))(rnd.randrange(2000, 9000)) + (rnd.choice([60, 75, 100, 150]),)),
    ]
    heavy = [12, 13, 14]
    return [templates[heavy[(i // 5) % len(heavy)] if i % 5 == 4 else i % len(templates)]()
            for i in range(n)]


# ---------------------------------------------------------------------------
# 002: index point lookups on a deep (1024-byte page) database
# ---------------------------------------------------------------------------


def db_index_lookups():
    """A trimmed OurAirports import in 1024-byte pages with six indexes."""
    path, con = G.new_db("airports_idx.sqlite", 1024)
    con.execute("""CREATE TABLE airport(
        id INTEGER PRIMARY KEY,
        ident TEXT NOT NULL,
        type TEXT,
        name TEXT,
        elevation_ft INTEGER,
        iso_country TEXT,
        iso_region TEXT,
        municipality TEXT,
        iata_code TEXT)""")
    rows = []
    for r in G.read_corpus_csv("airports.csv.gz"):
        rows.append((int(r["id"]), r["ident"], r["type"], r["name"],
                     G._num(r["elevation_ft"]), r["iso_country"], r["iso_region"],
                     r["municipality"] or None, r["iata_code"] or None))
    con.executemany("INSERT INTO airport VALUES(?,?,?,?,?,?,?,?,?)", rows)
    con.execute("""CREATE TABLE runway(
        id INTEGER PRIMARY KEY,
        airport_ref INTEGER,
        airport_ident TEXT,
        length_ft INTEGER,
        surface TEXT)""")
    rrows = []
    for r in G.read_corpus_csv("runways.csv.gz"):
        rrows.append((int(r["id"]), G._num(r["airport_ref"]), r["airport_ident"],
                      G._num(r["length_ft"]), r["surface"] or None))
    con.executemany("INSERT INTO runway VALUES(?,?,?,?,?)", rrows)
    con.execute("CREATE INDEX airport_ident ON airport(ident)")
    con.execute("CREATE INDEX airport_iata ON airport(iata_code)")
    con.execute("CREATE INDEX airport_city ON airport(municipality)")
    con.execute("CREATE INDEX airport_region ON airport(iso_region)")
    con.execute("CREATE INDEX runway_ref ON runway(airport_ref)")
    con.execute("CREATE INDEX runway_ident ON runway(airport_ident)")
    G.finish(con)
    return path


def queries_index_lookups(db, n=999, heavy=False):
    rnd = random.Random(20261011)
    idents = column(db, "SELECT ident FROM airport ORDER BY id")
    iatas = column(db, "SELECT iata_code FROM airport WHERE iata_code IS NOT NULL ORDER BY id")
    cities = column(db, "SELECT municipality FROM airport WHERE municipality IS NOT NULL "
                        "GROUP BY municipality HAVING count(*) <= 40 ORDER BY municipality")
    regions = column(db, "SELECT iso_region FROM airport GROUP BY iso_region "
                         "HAVING count(*) %s ORDER BY iso_region"
                         % ("BETWEEN 300 AND 5000" if heavy else "BETWEEN 20 AND 600"))
    refs = column(db, "SELECT DISTINCT airport_ref FROM runway WHERE airport_ref IS NOT NULL "
                      "ORDER BY airport_ref")
    rw_idents = column(db, "SELECT DISTINCT airport_ident FROM runway ORDER BY airport_ident")

    qs = []
    for _ in range(n):
        k = rnd.random()
        if k < 0.18:
            # Unique key; a few lookups miss on purpose.
            v = rnd.choice(idents) if rnd.random() < 0.95 else "ZZ%04d" % rnd.randrange(10000)
            qs.append("INDEX airport_ident %s" % lit(v))
        elif k < 0.23:
            qs.append("INDEX airport_iata %s" % lit(rnd.choice(iatas)))
        elif k < 0.35:
            qs.append("INDEX airport_city %s" % lit(rnd.choice(cities)))
        elif k < 0.80:
            # A region holds 20-600 airports, so these return whole runs of
            # equal keys that span several index pages.
            qs.append("INDEX airport_region %s" % lit(rnd.choice(regions)))
        elif k < 0.92:
            v = rnd.choice(refs)
            # Integer column: mix integer literals with numeric text literals
            # (the affinity conversion path).
            qs.append("INDEX runway_ref %s" % (lit(v) if rnd.random() < 0.8 else lit(str(v))))
        else:
            qs.append("INDEX runway_ident %s" % lit(rnd.choice(rw_idents)))
    return qs


# ---------------------------------------------------------------------------
# 003: many small mixed queries against Chinook
# ---------------------------------------------------------------------------


def queries_chinook_mixed(db, n=999, heavy=False):
    rnd = random.Random(31337)
    albums = column(db, "SELECT AlbumId FROM Album ORDER BY AlbumId")
    artists = column(db, "SELECT DISTINCT ArtistId FROM Album ORDER BY ArtistId")
    customers = column(db, "SELECT CustomerId FROM Customer ORDER BY CustomerId")
    invoices = column(db, "SELECT InvoiceId FROM Invoice ORDER BY InvoiceId")
    tracks = column(db, "SELECT TrackId FROM Track ORDER BY TrackId")
    genres = column(db, "SELECT GenreId FROM Genre ORDER BY GenreId")
    countries = column(db, "SELECT DISTINCT Country FROM Customer ORDER BY Country")
    bcountries = column(db, "SELECT DISTINCT BillingCountry FROM Invoice ORDER BY 1")
    composers = column(db, "SELECT Composer FROM Track WHERE Composer IS NOT NULL "
                           "GROUP BY Composer ORDER BY Composer")
    reps = column(db, "SELECT DISTINCT SupportRepId FROM Customer ORDER BY 1")
    tables = ["Album", "Artist", "Customer", "Employee", "Genre", "Invoice",
              "InvoiceLine", "MediaType", "Playlist", "PlaylistTrack", "Track"]

    templates = [
        (10, lambda: "INDEX IFK_TrackAlbumId %d" % rnd.choice(albums)),
        (8, lambda: "INDEX IFK_InvoiceCustomerId %d" % rnd.choice(customers)),
        (8, lambda: "INDEX IFK_InvoiceLineInvoiceId %d" % rnd.choice(invoices)),
        (6, lambda: "INDEX IFK_InvoiceLineTrackId %d" % rnd.choice(tracks)),
        (6, lambda: "INDEX IFK_PlaylistTrackTrackId %d" % rnd.choice(tracks)),
        (4, lambda: "INDEX IFK_AlbumArtistId %d" % rnd.choice(artists)),
        (2, lambda: "INDEX IFK_CustomerSupportRepId %d" % rnd.choice(reps)),
        (8, lambda: "SELECT TrackId,Name,Composer,Milliseconds FROM Track WHERE AlbumId = %d "
                    "ORDER BY Milliseconds DESC" % rnd.choice(albums)),
        (6, lambda: "SELECT TrackId,Name FROM Track WHERE GenreId = %d AND Milliseconds > %d "
                    "ORDER BY Name LIMIT 20" % (rnd.choice(genres), rnd.randrange(100000, 400000))),
        (6, lambda: "SELECT InvoiceId,InvoiceDate,Total FROM Invoice WHERE CustomerId = %s "
                    "ORDER BY InvoiceDate DESC" % (
                        lit(rnd.choice(customers)) if rnd.random() < 0.8
                        else lit(str(rnd.choice(customers))))),
        (4, lambda: "SELECT CustomerId,FirstName,LastName,City FROM Customer WHERE Country = %s "
                    "ORDER BY LastName" % lit(rnd.choice(countries))),
        (5, lambda: "SELECT InvoiceId,BillingCity,Total FROM Invoice WHERE BillingCountry = %s "
                    "AND Total >= %s ORDER BY Total DESC LIMIT 10" % (
                        lit(rnd.choice(bcountries)), rnd.choice(["1.98", "3.96", "5", "8.91"]))),
        (5, lambda: "SELECT TrackId,Name,AlbumId FROM Track WHERE Composer = %s ORDER BY Name"
                    % lit(rnd.choice(composers))),
        (6, lambda: "SELECT InvoiceLineId,TrackId,UnitPrice,Quantity FROM InvoiceLine "
                    "WHERE InvoiceId = %d" % rnd.choice(invoices)),
        (4, lambda: "SELECT PlaylistId FROM PlaylistTrack WHERE TrackId = %d"
                    % rnd.choice(tracks)),
        (3, lambda: "SELECT * FROM Album WHERE ArtistId = %d" % rnd.choice(artists)),
        (3, lambda: "SELECT * FROM Track WHERE TrackId >= %d AND TrackId < %d" % (
                        lambda a: (a, a + rnd.randrange(5, 30)))(rnd.choice(tracks))),
        (2, lambda: "SELECT TrackId,Name,Bytes FROM Track WHERE UnitPrice > 0.99 "
                    "AND MediaTypeId = %d ORDER BY Bytes DESC LIMIT 15" % rnd.randrange(1, 6)),
        (2, lambda: "SELECT Name,Milliseconds FROM Track ORDER BY Milliseconds DESC LIMIT 10"),
        (2, lambda: "SELECT * FROM Customer WHERE CustomerId = %d" % rnd.choice(customers)),
        (2, lambda: "COUNT %s" % rnd.choice(tables)),
        (1, lambda: "SELECT Title FROM Album ORDER BY Title LIMIT 10"),
        (1, lambda: ".schema %s" % rnd.choice(tables)),
        (1, lambda: ".tables"),
    ]
    if heavy:
        # Long tier: the filtered selects and sorts (scans) four times as often.
        templates = [(w * 4 if t().startswith("SELECT") else w, t) for w, t in templates]
    total = sum(w for w, _ in templates)
    qs = []
    for _ in range(n):
        x = rnd.randrange(total)
        for w, make in templates:
            if x < w:
                qs.append(make())
                break
            x -= w
    return qs


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------

CASES = [
    ("001_airports_scan", db_airports_scan, queries_airports_scan),
    ("002_index_lookups", db_index_lookups, queries_index_lookups),
    ("003_chinook_mixed", G.db_chinook, queries_chinook_mixed),
]


# Long tier (--long, written to ../bench-long). SPEC.md caps every input at
# 999 queries, so the long tier makes each query heavier instead.
LONG_DIR = os.path.join(PROBLEM, "bench-long")
LONG_CASES = [
    ("001_airports_scan", db_airports_scan, lambda db: queries_airports_scan_long(db, 999)),
    ("002_index_lookups", db_index_lookups, lambda db: queries_index_lookups(db, 999, heavy=True)),
    ("003_chinook_mixed", G.db_chinook, lambda db: queries_chinook_mixed(db, 999, heavy=True)),
]


def build_case(name, builder, make_queries, oracle, root=BENCH):
    db_src = builder()
    G.check_db_invariants(db_src)
    queries = make_queries(db_src)
    assert 1 <= len(queries) <= 999
    for q in queries:
        assert "\t" not in q and "\n" not in q and q == q.strip(), q

    case = os.path.join(root, name)
    if os.path.isdir(case):
        shutil.rmtree(case)
    indir = os.path.join(case, "input")
    expdir = os.path.join(case, "expected")
    os.makedirs(indir)
    db_dst = os.path.join(indir, os.path.basename(db_src))
    shutil.copyfile(db_src, db_dst)
    with open(os.path.join(indir, "queries.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(queries) + "\n")
    proc = subprocess.run([sys.executable, G.REFERENCE, indir, expdir],
                          capture_output=True, cwd=PROBLEM)
    if proc.returncode != 0:
        raise SystemExit("reference failed on %s: %s" % (name, proc.stderr.decode()))

    for i, line in enumerate(queries, 1):
        with open(os.path.join(expdir, "%03d.txt" % i), encoding="utf-8") as f:
            got = f.read()
        if G.normalize(got) == "error":
            raise SystemExit("%s query %d (%r) is an error" % (name, i, line))
        if not oracle:
            continue
        want = G.oracle_output(db_dst, line)
        if want is None:
            raise SystemExit("%s query %d (%r) has no oracle translation" % (name, i, line))
        if G.normalize(got) != G.normalize(want):
            raise SystemExit("ORACLE MISMATCH %s query %d: %r" % (name, i, line))
    sys.stderr.write("ok %s (%d queries%s)\n"
                     % (name, len(queries), ", cross-checked against sqlite3" if oracle else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--no-oracle", action="store_true",
                    help="skip the sqlite3 shell cross-check")
    ap.add_argument("--only", default="", help="comma-separated case name prefixes")
    ap.add_argument("--long", action="store_true", help="write the long tier to ../bench-long")
    args = ap.parse_args()
    root = LONG_DIR if args.long else BENCH
    os.makedirs(root, exist_ok=True)
    # The vendored corpora's licences travel with the databases built from them.
    shutil.copyfile(os.path.join(G.CORPUS, "chinook", "LICENSE.md"),
                    os.path.join(root, "LICENSE-chinook.md"))
    shutil.copyfile(os.path.join(G.CORPUS, "ourairports", "LICENSE.txt"),
                    os.path.join(root, "LICENSE-ourairports.txt"))
    with tempfile.TemporaryDirectory(prefix="sqlitefile_bench_") as tmp:
        G.WORK = tmp
        for name, builder, make_queries in (LONG_CASES if args.long else CASES):
            if args.only and not any(name.startswith(p) for p in args.only.split(",")):
                continue
            build_case(name, builder, make_queries, not args.no_oracle, root)
    size = sum(os.path.getsize(os.path.join(dp, f))
               for dp, _dn, fn in os.walk(root) for f in fn)
    sys.stderr.write("%s/ is %.1f MB\n" % (os.path.basename(root), size / 1e6))


if __name__ == "__main__":
    main()
