#!/usr/bin/env python3
"""Generates the performance benchmark inputs for the `scheme` problem.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as tests/,
so `run_tests.py scheme --tests-dir problems/scheme/bench` works. Programs are
deterministic (embedded data comes from fixed seeds) and expected outputs are
produced by reference/main.py.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, '..', 'reference', 'main.py')

PRELUDE = r'''
(define (reverse l) (let loop ((l l) (r '())) (if (null? l) r (loop (cdr l) (cons (car l) r)))))
(define (length l) (let loop ((l l) (n 0)) (if (null? l) n (loop (cdr l) (+ n 1)))))
(define (map f l)
  (let loop ((l l) (acc '())) (if (null? l) (reverse acc) (loop (cdr l) (cons (f (car l)) acc)))))
(define (filter p l)
  (let loop ((l l) (acc '()))
    (cond ((null? l) (reverse acc))
          ((p (car l)) (loop (cdr l) (cons (car l) acc)))
          (else (loop (cdr l) acc)))))
(define (fold f acc l) (if (null? l) acc (fold f (f acc (car l)) (cdr l))))
(define (cadr x) (car (cdr x)))
(define (caddr x) (car (cdr (cdr x))))
(define (cadddr x) (car (cdr (cdr (cdr x)))))
(define (abs x) (if (< x 0) (- x) x))
(define (take l n) (if (or (= n 0) (null? l)) '() (cons (car l) (take (cdr l) (- n 1)))))
'''

# ---------------------------------------------------------------------------
# 001: list and record processing over a large embedded dataset
# ---------------------------------------------------------------------------

FIRST = ['ada', 'alan', 'grace', 'edsger', 'barbara', 'donald', 'ken', 'dennis',
         'john', 'margaret', 'niklaus', 'tony', 'leslie', 'robin', 'frances', 'guido']
DEPTS = ['eng', 'ops', 'sales', 'legal', 'research', 'support', 'finance', 'hr']


def dataset(seed, n):
    rng = random.Random(seed)
    rows = []
    for i in range(n):
        name = '%s-%d' % (rng.choice(FIRST), i)
        dept = rng.choice(DEPTS)
        salary = rng.randint(30000, 250000)
        age = rng.randint(21, 67)
        tags = ' '.join(rng.sample(['remote', 'lead', 'oncall', 'new', 'senior', 'contract'],
                                   rng.randint(0, 3)))
        rows.append('("%s" %s %d %d (%s))' % (name, dept, salary, age, tags))
    out = []
    for k in range(0, n, 4):
        out.append(' '.join(rows[k:k + 4]))
    return '\n  '.join(out)


def bench_lists():
    data = dataset(20261011, 3000)
    return PRELUDE + r'''
(define (merge a b less?)
  (let loop ((a a) (b b) (acc '()))
    (cond ((null? a) (append-rev acc b))
          ((null? b) (append-rev acc a))
          ((less? (car b) (car a)) (loop a (cdr b) (cons (car b) acc)))
          (else (loop (cdr a) b (cons (car a) acc))))))
(define (append-rev r tail) (if (null? r) tail (append-rev (cdr r) (cons (car r) tail))))
(define (split l)
  (let loop ((l l) (a '()) (b '()))
    (if (null? l) (cons a b) (loop (cdr l) (cons (car l) b) a))))
(define (msort l less?)
  (if (or (null? l) (null? (cdr l))) l
      (let ((halves (split l)))
        (merge (msort (car halves) less?) (msort (cdr halves) less?) less?))))
(define (qsort l)
  (if (null? l) '()
      (let ((p (car l)))
        (let part ((r (cdr l)) (lo '()) (hi '()))
          (cond ((null? r) (append2 (qsort lo) (cons p (qsort hi))))
                ((< (car r) p) (part (cdr r) (cons (car r) lo) hi))
                (else (part (cdr r) lo (cons (car r) hi))))))))
(define (append2 a b) (append-rev (reverse a) b))
(define (lcg-list n seed)
  (let loop ((i 0) (x seed) (acc '()))
    (if (= i n) acc
        (let ((nx (remainder (+ (* x 1103515245) 12345) 2147483648)))
          (loop (+ i 1) nx (cons (remainder nx 1000000) acc))))))
(define (sorted? l)
  (or (null? l) (null? (cdr l))
      (and (<= (car l) (cadr l)) (sorted? (cdr l)))))
(define (dedup l)
  (let loop ((l l) (acc '()))
    (cond ((null? l) (reverse acc))
          ((and (pair? acc) (= (car acc) (car l))) (loop (cdr l) acc))
          (else (loop (cdr l) (cons (car l) acc))))))
(define (sum l) (fold + 0 l))
(define (checksum l) (fold (lambda (h x) (remainder (+ (* h 31) x) 1000000007)) 7 l))

(define nums (lcg-list 30000 42))
(define s1 (msort nums <))
(define s2 (qsort nums))
(sorted? s1)
(equal? s1 s2)
(checksum s1)
(length (dedup s1))
(define round-trip
  (let loop ((k 0) (acc 0))
    (if (= k 4) acc
        (let ((l (lcg-list 10000 (+ k 7))))
          (loop (+ k 1) (+ acc (checksum (msort (map (lambda (x) (- 1000000 x)) l) <))))))))
round-trip

(define staff '(
  ''' + data + r'''
  ))
(define (name r) (car r))
(define (dept r) (cadr r))
(define (salary r) (caddr r))
(define (age r) (cadddr r))
(define (tags r) (car (cdr (cdr (cdr (cdr r))))))
(length staff)
(define by-salary (msort staff (lambda (a b) (< (salary a) (salary b)))))
(name (car by-salary))
(name (car (reverse by-salary)))
(define (assq-ref key al) (cond ((null? al) #f) ((eq? (car (car al)) key) (car al)) (else (assq-ref key (cdr al)))))
(define (group rows key)
  (let loop ((ks '(eng ops sales legal research support finance hr)) (acc '()))
    (if (null? ks) (reverse acc)
        (loop (cdr ks)
              (cons (cons (car ks) (filter (lambda (r) (eq? (key r) (car ks))) rows)) acc)))))
(define groups (group staff dept))
(define (stats g)
  (let ((rows (cdr g)))
    (list (car g) (length rows) (quotient (sum (map salary rows)) (length rows))
          (fold (lambda (m r) (if (> (age r) m) (age r) m)) 0 rows))))
(map stats groups)
(define (member? x l) (cond ((null? l) #f) ((eq? (car l) x) #t) (else (member? x (cdr l)))))
(define (tagged t) (filter (lambda (r) (member? t (tags r))) staff))
(map (lambda (t) (cons t (length (tagged t)))) '(remote lead oncall new senior contract))
(define (string-join strs sep)
  (if (null? strs) ""
      (fold (lambda (acc s) (string-append acc sep s)) (car strs) (cdr strs))))
(define report
  (string-join (map (lambda (r) (string-append (name r) ":" (number->string (salary r))))
                    (take (reverse by-salary) 200))
               ","))
(string-length report)
(define (repeat-sort k acc)
  (if (= k 0) acc
      (repeat-sort (- k 1)
        (+ acc (checksum (map salary (msort staff (lambda (a b)
                                                    (or (< (age a) (age b))
                                                        (and (= (age a) (age b))
                                                             (< (salary a) (salary b))))))))))))
(repeat-sort 6 0)
(define (assoc-str s al) (cond ((null? al) #f) ((equal? (car (car al)) s) (car al)) (else (assoc-str s (cdr al)))))
(define lookups
  (let loop ((rs (take staff 200)) (hits 0))
    (if (null? rs) hits
        (loop (cdr rs) (if (assoc-str (name (car rs)) staff) (+ hits 1) hits)))))
lookups
'''


# ---------------------------------------------------------------------------
# 002: call-intensive interpretation core: recursion, closures, tail calls
# ---------------------------------------------------------------------------

def bench_calls():
    return PRELUDE + r'''
(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(fib 27)
(define (tak x y z) (if (not (< y x)) z (tak (tak (- x 1) y z) (tak (- y 1) z x) (tak (- z 1) x y))))
(tak 22 16 8)
(define (ack m n)
  (cond ((= m 0) (+ n 1))
        ((= n 0) (ack (- m 1) 1))
        (else (ack (- m 1) (ack m (- n 1))))))
(ack 2 9)
(ack 3 6)
(define (queens n)
  (define (safe? col placed dist)
    (cond ((null? placed) #t)
          ((or (= (car placed) col) (= (abs (- (car placed) col)) dist)) #f)
          (else (safe? col (cdr placed) (+ dist 1)))))
  (define (place k placed)
    (if (= k n) 1
        (let loop ((col 0) (total 0))
          (if (= col n) total
              (loop (+ col 1)
                    (+ total (if (safe? col placed 1) (place (+ k 1) (cons col placed)) 0)))))))
  (place 0 '()))
(queens 9)
(define (count-change amount coins)
  (cond ((= amount 0) 1)
        ((or (< amount 0) (null? coins)) 0)
        (else (+ (count-change amount (cdr coins))
                 (count-change (- amount (car coins)) coins)))))
(count-change 300 '(50 25 10 5 1))
(letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1)))))
         (od? (lambda (n) (if (= n 0) #f (ev? (- n 1))))))
  (list (ev? 1000000) (od? 777777)))
(define (make-counter)
  (let ((n 0)) (lambda () (set! n (+ n 1)) n)))
(define (run-counters k)
  (let ((cs (map (lambda (i) (make-counter)) '(1 2 3 4 5 6 7 8 9 10))))
    (let loop ((i 0))
      (if (= i k) (fold + 0 (map (lambda (c) (c)) cs))
          (begin (for-each-c cs) (loop (+ i 1)))))))
(define (for-each-c cs) (if (null? cs) #t (begin ((car cs)) (for-each-c (cdr cs)))))
(run-counters 30000)
(define (cps-fact n k) (if (= n 0) (k 1) (cps-fact (- n 1) (lambda (v) (k (* n v))))))
(define (cps-loop i acc) (if (= i 0) acc (cps-loop (- i 1) (+ acc (remainder (cps-fact 20 (lambda (v) v)) 1000)))))
(cps-loop 20000 0)
(define (compose . fs)
  (if (null? fs) (lambda (x) x)
      (lambda (x) ((car fs) ((apply compose (cdr fs)) x)))))
(define inc3 (compose (lambda (x) (+ x 1)) (lambda (x) (+ x 1)) (lambda (x) (+ x 1))))
(let loop ((i 0) (acc 0)) (if (= i 100000) acc (loop (+ i 1) (inc3 acc))))
(define (vsum . xs) (fold + 0 xs))
(let loop ((i 0) (acc 0)) (if (= i 200000) acc (loop (+ i 1) (apply vsum i 1 2 '(3 4)))))

(define (lookup var env)
  (cond ((null? env) (error "unbound" var))
        ((eq? (car (car env)) var) (cdr (car env)))
        (else (lookup var (cdr env)))))
(define (meval e env)
  (cond ((number? e) e)
        ((boolean? e) e)
        ((symbol? e) (lookup e env))
        ((eq? (car e) 'quote) (cadr e))
        ((eq? (car e) 'lambda) (list 'closure (cadr e) (caddr e) env))
        ((eq? (car e) 'if)
         (if (meval (cadr e) env) (meval (caddr e) env) (meval (cadddr e) env)))
        (else (mapply (meval (car e) env) (map (lambda (x) (meval x env)) (cdr e))))))
(define (bind params args env)
  (if (null? params) env
      (cons (cons (car params) (car args)) (bind (cdr params) (cdr args) env))))
(define (mapply f args)
  (cond ((procedure? f) (apply f args))
        ((and (pair? f) (eq? (car f) 'closure))
         (meval (caddr f) (bind (cadr f) args (cadddr f))))
        (else (error "not applicable" f))))
(define genv (list (cons '+ +) (cons '- -) (cons '* *) (cons '= =) (cons '< <)
                   (cons 'cons cons) (cons 'car car) (cons 'cdr cdr) (cons 'null? null?)))
(meval '((lambda (fib) (fib fib 18))
         (lambda (self n) (if (< n 2) n (+ (self self (- n 1)) (self self (- n 2))))))
       genv)
(define (deep n) (if (= n 0) 0 (+ 1 (deep (- n 1)))))
(let loop ((i 0) (acc 0)) (if (= i 50) acc (loop (+ i 1) (+ acc (deep 10000)))))
'''


# ---------------------------------------------------------------------------
# 003: mixed workload with arbitrary-precision arithmetic and output
# ---------------------------------------------------------------------------

def bench_bignum():
    return PRELUDE + r'''
(define (pi-digits n)
  (let loop ((q 1) (r 0) (t 1) (k 1) (m 3) (x 3) (count 0) (acc '()))
    (cond ((= count n) (reverse acc))
          ((< (+ (* 4 q) (- r t)) (* m t))
           (loop (* 10 q) (* 10 (- r (* m t))) t k
                 (- (quotient (* 10 (+ (* 3 q) r)) t) (* 10 m)) x (+ count 1) (cons m acc)))
          (else
           (loop (* q k) (* (+ (* 2 q) r) x) (* t x) (+ k 1)
                 (quotient (+ (* q (+ (* 7 k) 2)) (* r x)) (* t x)) (+ x 2) count acc)))))
(define (digits->string ds) (fold (lambda (s d) (string-append s (number->string d))) "" ds))
(define pi (digits->string (pi-digits 1500)))
(display (string-length pi)) (newline)
(display pi) (newline)
(define (fact n) (let loop ((i 1) (acc 1)) (if (> i n) acc (loop (+ i 1) (* acc i)))))
(define (digit-sum n) (let loop ((n n) (s 0)) (if (= n 0) s (loop (quotient n 10) (+ s (remainder n 10))))))
(define f5000 (fact 5000))
(string-length (number->string f5000))
(digit-sum f5000)
(define (fib-iter n) (let loop ((i 0) (a 0) (b 1)) (if (= i n) a (loop (+ i 1) b (+ a b)))))
(define f40000 (fib-iter 40000))
(string-length (number->string f40000))
(remainder f40000 1000000007)
(define (expt b e)
  (cond ((= e 0) 1)
        ((= (remainder e 2) 0) (let ((h (expt b (quotient e 2)))) (* h h)))
        (else (* b (expt b (- e 1))))))
(define (isqrt n)
  (let loop ((x (expt 10 (quotient (+ (string-length (number->string n)) 1) 2))))
    (let ((y (quotient (+ x (quotient n x)) 2)))
      (if (>= y x) x (loop y)))))
(define sqrt2 (isqrt (* 2 (expt 10 6000))))
(display (string-length (number->string sqrt2))) (newline)
(remainder sqrt2 (expt 10 50))
(define (gcd a b) (if (= b 0) (abs a) (gcd b (remainder a b))))
(gcd (* (fib-iter 3001) (fact 400)) (* (fib-iter 3003) (fact 410)))
(define (powmod b e m)
  (cond ((= e 0) 1)
        ((= (remainder e 2) 0) (let ((h (powmod b (quotient e 2) m))) (remainder (* h h) m)))
        (else (remainder (* b (powmod b (- e 1) m)) m))))
(define big-m (- (expt 2 521) 1))
(powmod 3 (- big-m 1) big-m)
(define (prime? n)
  (and (> n 1)
       (let loop ((as '(2 3 5 7 11 13 17 19 23 29 31 37)))
         (or (null? as) (= (car as) n)
             (and (= (powmod (car as) (- n 1) n) 1) (loop (cdr as)))))))
(define (next-prime n) (if (prime? n) n (next-prime (+ n 1))))
(next-prime (expt 10 60))
(define (collatz n) (let loop ((n n) (k 0)) (if (= n 1) k (loop (if (= (remainder n 2) 0) (quotient n 2) (+ (* 3 n) 1)) (+ k 1)))))
(collatz (+ (expt 3 200) 1))
(define (binom n k) (quotient (fact n) (* (fact k) (fact (- n k)))))
(string-length (number->string (binom 2000 1000)))
(define (table n)
  (let row ((i 1))
    (if (<= i n)
        (begin
          (display (string-append (number->string i) "! = "
                                  (number->string (remainder (fact (* i 10)) 1000000007))))
          (newline)
          (row (+ i 1))))))
(table 60)
(define (harmonic-num n)
  (let loop ((i 1) (num 0) (den 1))
    (if (> i n) (list num den)
        (let* ((nn (+ (* num i) den)) (dd (* den i)) (g (gcd nn dd)))
          (loop (+ i 1) (quotient nn g) (quotient dd g))))))
(define h (harmonic-num 1000))
(string-length (number->string (car h)))
(remainder (cadr h) 1000000007)
'''


CASES = [
    ('list_sort_records', bench_lists),
    ('call_intensive', bench_calls),
    ('bignum_mixed', bench_bignum),
]


# Long tier (bench-long/): the same programs with their loop counts and
# problem sizes raised so the fastest implementation needs >= 5 s. Each pair
# replaces exactly one occurrence in the short program.
LONG_SUBS = {
    'list_sort_records': [
        ('(lcg-list 30000 42)', '(lcg-list 80000 42)'),
        ('(if (= k 4) acc', '(if (= k 48) acc'),
        ('(repeat-sort 6 0)', '(repeat-sort 80 0)'),
    ],
    'call_intensive': [
        ('(fib 27)', '(fib 32)'),
        ('(tak 22 16 8)', '(tak 24 16 8)'),
        ('(ack 3 6)', '(ack 3 7)'),
        ('(queens 9)', '(queens 10)'),
        ("(count-change 300 '(50 25 10 5 1))", "(count-change 500 '(50 25 10 5 1))"),
        ('(list (ev? 1000000) (od? 777777))', '(list (ev? 5000000) (od? 3999999))'),
        ('(run-counters 30000)', '(run-counters 200000)'),
        ('(cps-loop 20000 0)', '(cps-loop 140000 0)'),
        ('(if (= i 100000) acc (loop (+ i 1) (inc3 acc)))', '(if (= i 500000) acc (loop (+ i 1) (inc3 acc)))'),
        ('(if (= i 200000) acc', '(if (= i 1000000) acc'),
        ('(fib fib 18)', '(fib fib 22)'),
        ('(if (= i 50) acc (loop (+ i 1) (+ acc (deep 10000))))', '(if (= i 340) acc (loop (+ i 1) (+ acc (deep 10000))))'),
    ],
    'bignum_mixed': [
        ('(pi-digits 1500)', '(pi-digits 4800)'),
        ('(define f5000 (fact 5000))', '(define f5000 (fact 16000))'),
        ('(define f40000 (fib-iter 40000))', '(define f40000 (fib-iter 250000))'),
        ('(expt 10 6000)', '(expt 10 12000)'),
        ('(collatz (+ (expt 3 200) 1))', '(collatz (+ (expt 3 400) 1))'),
        ('(binom 2000 1000)', '(binom 4000 2000)'),
        ('(table 60)', '(table 240)'),
        ('(harmonic-num 1000)', '(harmonic-num 3500)'),
    ],
}


def long_program(name, program):
    for old, new in LONG_SUBS[name]:
        assert program.count(old) == 1, (name, old)
        program = program.replace(old, new)
    return program


def main():
    sys.set_int_max_str_digits(0)
    out_dir = HERE
    if '--long' in sys.argv:
        out_dir = os.path.join(HERE, '..', 'bench-long')
        os.makedirs(out_dir, exist_ok=True)
    for i, (name, fn) in enumerate(CASES, 1):
        base = os.path.join(out_dir, '%03d_%s' % (i, name))
        program = fn()
        if '--long' in sys.argv:
            program = long_program(name, program)
        assert len(program.encode('utf-8')) <= 200_000, name
        with open(base + '.in', 'w', encoding='utf-8') as f:
            f.write(program)
        if '--no-expected' in sys.argv:
            continue
        proc = subprocess.run([sys.executable, REF], input=program.encode('utf-8'),
                              capture_output=True, timeout=1200)
        if proc.returncode != 0:
            raise RuntimeError('reference crashed on %s: %s' % (name, proc.stderr.decode()))
        with open(base + '.out', 'wb') as f:
            f.write(proc.stdout)
        print('wrote %s (%d bytes in, %d bytes out)' % (base, len(program), len(proc.stdout)))


if __name__ == '__main__':
    main()
