#!/usr/bin/env python3
"""Generates the minisql performance benchmark inputs (bench/NNN_name.in) and
their expected outputs (bench/NNN_name.out) deterministically.

Expected outputs come from reference/main.py. Table sizes stay at the sizes the
spec's Performance section describes (at most 20 000 rows per table, inserted
500 rows per statement); the work per input comes from running many queries
over those tables.

Usage: python3 gen_bench.py [--no-ref] [--long]
  --no-ref writes only the .in files; --long writes the long tier (same three
  inputs with more statements, see NOTES.md) to ../bench-long/.
"""
import os
import random
import subprocess
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, '..', 'reference', 'main.py')

FIRST = ['alice', 'bob', 'carol', 'dave', 'erin', 'frank', 'grace', 'heidi', 'ivan', 'judy',
         'mallory', 'oscar', 'peggy', 'trent', 'victor', 'wendy', 'Al', 'Bea', 'kim', 'lou']
CITIES = ['austin', 'boston', 'chicago', 'denver', 'erie', 'fargo', 'gary', 'houston', 'irvine',
          'juneau', 'kent', 'laredo', 'macon', 'nome', 'omaha', 'provo']
STATUSES = ['new', 'paid', 'shipped', 'done', 'cancelled', 'returned']
CATEGORIES = ['books', 'games', 'garden', 'tools', 'toys', 'food', 'music', 'office']
WORDS = ['red', 'blue', 'mini', 'max', 'pro', 'lite', 'eco', 'deluxe', 'basic', 'ultra', "o'neil"]


def lit(v):
    if v is None:
        return 'NULL'
    if isinstance(v, str):
        return "'" + v.replace("'", "''") + "'"
    return str(v)


def bulk_insert(table, rows, chunk=500):
    return ['INSERT INTO %s VALUES %s;' % (table, ', '.join('(' + ', '.join(lit(v) for v in r) + ')'
                                                              for r in rows[i:i + chunk]))
            for i in range(0, len(rows), chunk)]


def dataset(rnd, n_users=2000, n_products=500, n_orders=20000):
    """users / products / orders tables; returns (statements, users, orders)."""
    out = ['CREATE TABLE users (id INTEGER, name TEXT, city TEXT, age INTEGER, tier INTEGER);',
           'CREATE TABLE products (id INTEGER, title TEXT, category TEXT, price INTEGER);',
           'CREATE TABLE orders (id INTEGER, user_id INTEGER, product_id INTEGER, qty INTEGER, '
           'amount INTEGER, status TEXT, note TEXT);']
    users = [(i, rnd.choice(FIRST) + str(rnd.randint(1, 999)),
              rnd.choice(CITIES) if rnd.random() < 0.97 else None,
              rnd.randint(18, 80) if rnd.random() < 0.95 else None,
              rnd.randint(1, 4)) for i in range(1, n_users + 1)]
    products = [(i, rnd.choice(WORDS) + ' ' + rnd.choice(CATEGORIES)[:-1] + ' ' + str(i),
                 rnd.choice(CATEGORIES), rnd.randint(1, 400) * 25) for i in range(1, n_products + 1)]
    orders = []
    for i in range(1, n_orders + 1):
        qty = rnd.randint(1, 9)
        orders.append((i, rnd.randint(1, n_users + 40), rnd.randint(1, n_products), qty,
                       rnd.randint(1, 5000) if rnd.random() < 0.97 else None,
                       rnd.choice(STATUSES),
                       rnd.choice(WORDS) + '-' + str(rnd.randint(0, 99)) if rnd.random() < 0.6 else None))
    out += bulk_insert('users', users) + bulk_insert('products', products) + bulk_insert('orders', orders)
    return out, n_users, n_products, n_orders


# ---------------------------------------------------------------------------
# 001: single-table scans, filters, sorting and grouping
# ---------------------------------------------------------------------------

def bench_scan(seed=7001, n_queries=420):
    rnd = random.Random(seed)
    out, nu, npr, no = dataset(rnd)

    def st():
        return lit(rnd.choice(STATUSES))

    def city():
        return lit(rnd.choice(CITIES))

    def amt():
        return rnd.randint(100, 4900)

    def pat():
        return lit(rnd.choice(['a%', '%e%', '%o_', 'b%1', '%pro%', 'RED%', '_l%', '%9', 'eco-1_', '%a%e%']))

    q = [
        lambda: 'SELECT COUNT(*), SUM(amount), MIN(amount), MAX(amount), AVG(amount) FROM orders WHERE status = %s;' % st(),
        lambda: 'SELECT id, user_id, amount FROM orders WHERE status = %s AND amount > %d ORDER BY amount DESC, id LIMIT 20;' % (st(), amt()),
        lambda: 'SELECT id, note FROM orders WHERE note LIKE %s AND qty >= %d ORDER BY id LIMIT 25;' % (pat(), rnd.randint(1, 9)),
        lambda: 'SELECT COUNT(*) FROM orders WHERE amount %% %d = %d AND status NOT LIKE %s;' % (rnd.randint(3, 17), rnd.randint(0, 2), lit(rnd.choice(['%e%', 'p%', '%d', '_a%']))),
        lambda: 'SELECT status, COUNT(*), SUM(qty), AVG(amount) FROM orders GROUP BY status;',
        lambda: 'SELECT user_id, COUNT(*) AS n, SUM(amount) AS s FROM orders GROUP BY user_id HAVING SUM(amount) > %d ORDER BY s DESC, user_id LIMIT 15;' % rnd.randint(40000, 60000),
        lambda: 'SELECT product_id, COUNT(*), MAX(amount) FROM orders WHERE qty > %d GROUP BY product_id HAVING COUNT(*) >= %d ORDER BY 2 DESC, 1 LIMIT 10;' % (rnd.randint(3, 7), rnd.randint(8, 15)),
        lambda: 'SELECT id, amount * qty - %d AS v FROM orders WHERE amount IS NOT NULL ORDER BY v DESC, id LIMIT 10 OFFSET %d;' % (rnd.randint(0, 500), rnd.randint(0, 5000)),
        lambda: 'SELECT id, status, amount FROM orders ORDER BY status, amount DESC, id LIMIT 20 OFFSET %d;' % rnd.randint(0, 19000),
        lambda: 'SELECT id, name, age FROM users WHERE city = %s AND (age < %d OR tier = %d) ORDER BY name, id LIMIT 30;' % (city(), rnd.randint(20, 40), rnd.randint(1, 4)),
        lambda: 'SELECT city, tier, COUNT(*), MIN(age), MAX(age), AVG(age) FROM users GROUP BY city, tier HAVING COUNT(*) > %d;' % rnd.randint(25, 40),
        lambda: 'SELECT name FROM users WHERE name LIKE %s ORDER BY name DESC LIMIT 12;' % lit(rnd.choice(FIRST)[:2] + '%' + str(rnd.randint(1, 9))),
        lambda: 'SELECT amount / 500, COUNT(*), SUM(qty) FROM orders WHERE amount IS NOT NULL AND status != %s GROUP BY amount HAVING COUNT(*) > %d ORDER BY 2 DESC, amount LIMIT 8;' % (st(), rnd.randint(4, 8)),
        lambda: 'SELECT COUNT(*), COUNT(note), MIN(note), MAX(note) FROM orders WHERE NOT (amount > %d AND qty < %d);' % (amt(), rnd.randint(2, 8)),
        lambda: 'SELECT id FROM orders WHERE amount IS NULL OR (user_id > %d AND status = %s) ORDER BY id DESC LIMIT 15;' % (rnd.randint(1900, 2030), st()),
        lambda: 'SELECT category, COUNT(*), AVG(price), MIN(title), MAX(title) FROM products GROUP BY category;',
        lambda: 'SELECT note, COUNT(*) FROM orders GROUP BY note HAVING COUNT(*) >= %d ORDER BY 2 DESC, 1 LIMIT 10;' % rnd.randint(12, 20),
        lambda: 'SELECT -amount + qty * %d, id FROM orders WHERE id %% %d = 0 ORDER BY 1, 2 LIMIT 10;' % (rnd.randint(1, 100), rnd.randint(50, 400)),
    ]
    mut = [
        lambda: 'UPDATE orders SET amount = amount + %d WHERE status = %s AND amount < %d;' % (rnd.randint(-50, 50), st(), amt()),
        lambda: 'UPDATE orders SET status = %s, qty = qty + 1 WHERE id %% %d = %d;' % (st(), rnd.randint(20, 60), rnd.randint(0, 19)),
        lambda: 'UPDATE users SET tier = tier %% 4 + 1 WHERE city = %s;' % city(),
    ]
    for i in range(n_queries):
        if i % 30 == 29:
            out.append(rnd.choice(mut)())
        else:
            out.append(rnd.choice(q)())
    out.append('SELECT id, user_id, product_id, qty, amount, status, note FROM orders ORDER BY amount DESC, status, id;')
    return '\n'.join(out) + '\n'


# ---------------------------------------------------------------------------
# 002: equality joins (two-table and self joins) with filters and grouping
# ---------------------------------------------------------------------------

def bench_join(seed=7002, n_queries=150):
    rnd = random.Random(seed)
    out, nu, npr, no = dataset(rnd)

    def st():
        return lit(rnd.choice(STATUSES))

    def city():
        return lit(rnd.choice(CITIES))

    def cat():
        return lit(rnd.choice(CATEGORIES))

    q = [
        lambda: 'SELECT u.city, COUNT(*), SUM(o.amount), AVG(o.amount) FROM orders o JOIN users u ON o.user_id = u.id WHERE o.status = %s GROUP BY u.city;' % st(),
        lambda: 'SELECT u.name, SUM(o.amount) AS total FROM users u INNER JOIN orders o ON u.id = o.user_id WHERE u.tier = %d GROUP BY u.name HAVING SUM(o.amount) > %d ORDER BY total DESC, u.name LIMIT 12;' % (rnd.randint(1, 4), rnd.randint(30000, 50000)),
        lambda: 'SELECT o.id, u.name, o.amount FROM orders o, users u WHERE o.user_id = u.id AND u.city = %s AND o.amount > %d ORDER BY o.amount DESC, o.id LIMIT 20;' % (city(), rnd.randint(4000, 4900)),
        lambda: 'SELECT p.category, COUNT(*), SUM(o.qty), AVG(o.amount) FROM orders o JOIN products p ON o.product_id = p.id WHERE o.status != %s GROUP BY p.category ORDER BY 3 DESC;' % st(),
        lambda: 'SELECT p.title, COUNT(*) AS n FROM products p JOIN orders o ON p.id = o.product_id WHERE p.category = %s AND o.qty >= %d GROUP BY p.title ORDER BY n DESC, p.title LIMIT 10;' % (cat(), rnd.randint(4, 8)),
        lambda: 'SELECT COUNT(*), SUM(o.qty * p.price) FROM orders o JOIN products p ON o.product_id = p.id AND o.amount < p.price / %d;' % rnd.randint(1, 4),
        lambda: 'SELECT a.city, COUNT(*) FROM users a JOIN users b ON a.city = b.city WHERE a.id < b.id AND a.age = b.age GROUP BY a.city ORDER BY 2 DESC, 1;',
        lambda: 'SELECT a.id, b.id, a.name FROM users a, users b WHERE a.age = b.age AND a.tier = b.tier AND a.city = %s AND b.city = %s AND a.id < b.id ORDER BY a.id, b.id LIMIT 25;' % (city(), city()),
        lambda: 'SELECT a.age, COUNT(*), MIN(b.id) FROM users a JOIN users b ON a.age + %d = b.age WHERE a.tier = b.tier GROUP BY a.age HAVING COUNT(*) > %d ORDER BY 2 DESC, 1 LIMIT 10;' % (rnd.randint(1, 5), rnd.randint(150, 220)),
        lambda: 'SELECT o.user_id, COUNT(*) FROM orders o JOIN orders q ON o.user_id = q.user_id WHERE o.id < q.id AND o.product_id = q.product_id GROUP BY o.user_id ORDER BY 2 DESC, 1 LIMIT 10;',
        lambda: 'SELECT o.id, q.id FROM orders o JOIN orders q ON o.amount = q.amount WHERE o.id < q.id AND o.status = %s AND q.status = %s ORDER BY o.id, q.id LIMIT 30;' % (st(), st()),
        lambda: 'SELECT COUNT(*), AVG(q.amount) FROM orders o JOIN orders q ON o.user_id = q.user_id AND o.qty = q.qty WHERE o.id != q.id;',
        lambda: 'SELECT u.id, u.name, COUNT(o.note), MAX(o.amount) FROM users u JOIN orders o ON o.user_id = u.id WHERE u.age > %d GROUP BY u.id, u.name HAVING COUNT(*) >= %d ORDER BY 3 DESC, 1 LIMIT 10;' % (rnd.randint(30, 70), rnd.randint(12, 16)),
        lambda: 'SELECT u.city, o.status, COUNT(*) FROM users u, orders o WHERE u.id = o.user_id AND u.age < %d GROUP BY u.city, o.status HAVING COUNT(*) > %d ORDER BY u.city, o.status;' % (rnd.randint(25, 60), rnd.randint(20, 60)),
        lambda: 'SELECT COUNT(*) FROM orders o JOIN users u ON o.user_id = u.id WHERE u.city IS NULL OR o.note LIKE %s;' % lit(rnd.choice(['red%', '%-1', 'max-_', '%o%'])),
        lambda: 'SELECT o.id, p.title FROM products p JOIN orders o ON o.product_id = p.id WHERE p.price = %d ORDER BY o.id LIMIT 15;' % (rnd.randint(1, 400) * 25),
    ]
    for _ in range(n_queries):
        out.append(rnd.choice(q)())
    out.append('SELECT o.id, u.name, u.city, o.amount FROM orders o JOIN users u ON o.user_id = u.id WHERE o.qty > 6;')
    return '\n'.join(out) + '\n'


# ---------------------------------------------------------------------------
# 003: mixed OLTP-style workload: point reads/writes plus periodic reports
# ---------------------------------------------------------------------------

def bench_mixed(seed=7003, n_stmts=4500):
    rnd = random.Random(seed)
    out, nu, npr, no = dataset(rnd, n_orders=19000)
    next_order = [no + 1]
    next_user = [nu + 1]

    def oid():
        return rnd.randint(1, next_order[0] - 1)

    def uid():
        return rnd.randint(1, next_user[0] - 1)

    def new_order():
        i = next_order[0]
        next_order[0] += 1
        return '(%d, %d, %d, %d, %s, %s, %s)' % (
            i, uid(), rnd.randint(1, npr), rnd.randint(1, 9), lit(rnd.randint(1, 5000)),
            lit(rnd.choice(STATUSES[:2])), lit(rnd.choice([None, 'web-' + str(rnd.randint(0, 99))])))

    def ins_orders():
        return 'INSERT INTO orders VALUES %s;' % ', '.join(new_order() for _ in range(rnd.randint(1, 3)))

    def ins_user():
        i = next_user[0]
        next_user[0] += 1
        return "INSERT INTO users VALUES (%d, %s, %s, %d, 1);" % (
            i, lit(rnd.choice(FIRST) + str(rnd.randint(1, 999))), lit(rnd.choice(CITIES)), rnd.randint(18, 80))

    ops = [
        (18, lambda: 'SELECT id, user_id, product_id, qty, amount, status, note FROM orders WHERE id = %d;' % oid()),
        (10, lambda: 'SELECT id, amount, status FROM orders WHERE user_id = %d ORDER BY id DESC LIMIT 5;' % uid()),
        (8, lambda: 'SELECT name, city, age, tier FROM users WHERE id = %d;' % uid()),
        (12, ins_orders),
        (2, ins_user),
        (12, lambda: "UPDATE orders SET status = %s WHERE id = %d;" % (lit(rnd.choice(STATUSES[1:4])), oid())),
        (5, lambda: 'UPDATE orders SET qty = qty + 1, amount = amount + %d WHERE id = %d AND status = %s;' % (rnd.randint(1, 300), oid(), lit(rnd.choice(STATUSES[:2])))),
        (3, lambda: 'UPDATE users SET tier = tier + 1 WHERE id = %d AND tier < 4;' % uid()),
        (4, lambda: 'DELETE FROM orders WHERE id = %d;' % oid()),
        (5, lambda: 'SELECT COUNT(*), SUM(amount) FROM orders WHERE user_id = %d AND status != %s;' % (uid(), lit('cancelled'))),
        (3, lambda: 'SELECT o.id, p.title, o.qty FROM orders o JOIN products p ON o.product_id = p.id WHERE o.user_id = %d ORDER BY o.id;' % uid()),
        (1, lambda: 'SELECT id FROM orders WHERE note = %s ORDER BY id DESC LIMIT 3;' % lit('web-' + str(rnd.randint(0, 99)))),
        (1, lambda: 'SELECT * FROM orders WHERE id = %d AND nosuch = 1;' % oid()),
        (1, lambda: 'INSERT INTO orders VALUES (%d, %d);' % (oid(), uid())),
    ]
    weights = [w for w, _ in ops]
    fns = [f for _, f in ops]
    reports = [
        lambda: 'SELECT status, COUNT(*), SUM(amount), AVG(amount) FROM orders GROUP BY status;',
        lambda: 'SELECT u.city, COUNT(*), SUM(o.amount) FROM orders o JOIN users u ON o.user_id = u.id WHERE o.status = %s GROUP BY u.city ORDER BY 3 DESC, 1;' % lit(rnd.choice(STATUSES)),
        lambda: 'SELECT p.category, SUM(o.qty), AVG(o.amount) FROM orders o JOIN products p ON o.product_id = p.id GROUP BY p.category ORDER BY 2 DESC;',
        lambda: 'SELECT user_id, COUNT(*), SUM(amount) AS s FROM orders GROUP BY user_id ORDER BY s DESC, user_id LIMIT 10;',
        lambda: 'SELECT id, amount FROM orders WHERE status = %s ORDER BY amount DESC, id LIMIT 10;' % lit(rnd.choice(STATUSES)),
        lambda: "DELETE FROM orders WHERE status = 'cancelled' AND amount < %d;" % rnd.randint(200, 800),
    ]
    for i in range(n_stmts):
        if i % 150 == 149:
            out.append(rnd.choice(reports)())
        else:
            out.append(rnd.choices(fns, weights)[0]())
    out.append('SELECT COUNT(*), SUM(amount), SUM(qty), MIN(id), MAX(id) FROM orders;')
    out.append('SELECT id, user_id, qty, amount, status FROM orders WHERE id > %d ORDER BY id;' % no)
    return '\n'.join(out) + '\n'


CASES = [
    ('scan_filter_group', bench_scan),
    ('equi_joins', bench_join),
    ('mixed_oltp', bench_mixed),
]

# Long tier: the same generators with more statements over the same tables.
LONG_CASES = [
    ('scan_filter_group', lambda: bench_scan(n_queries=7600)),
    ('equi_joins', lambda: bench_join(n_queries=6400)),
    ('mixed_oltp', lambda: bench_mixed(n_stmts=36000)),
]


def main():
    run_ref = '--no-ref' not in sys.argv[1:]
    long_tier = '--long' in sys.argv[1:]
    out_dir = os.path.join(HERE, '..', 'bench-long') if long_tier else HERE
    os.makedirs(out_dir, exist_ok=True)
    for n, (name, fn) in enumerate(LONG_CASES if long_tier else CASES, 1):
        base = '%03d_%s' % (n, name)
        text = fn()
        in_path = os.path.join(out_dir, base + '.in')
        with open(in_path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        msg = '%-24s %8d bytes in' % (base, len(text))
        if run_ref:
            proc = subprocess.run([sys.executable, REF], input=text.encode('utf-8'),
                                  capture_output=True, timeout=5400)
            if proc.returncode != 0:
                sys.exit('reference failed on %s:\n%s' % (base, proc.stderr.decode()))
            with open(os.path.join(out_dir, base + '.out'), 'wb') as f:
                f.write(proc.stdout)
            msg += ', %7d lines out' % proc.stdout.count(b'\n')
        print(msg)


if __name__ == '__main__':
    main()
