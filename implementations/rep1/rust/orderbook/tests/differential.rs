//! Randomised differential test: the real book against a deliberately naive
//! reference model that keeps all resting orders in one flat vector and
//! re-scans it for every decision.

use orderbook::{Command, Event, OrderBook, OrderId, Side, TimeInForce};

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

#[derive(Clone)]
struct Resting {
    id: OrderId,
    side: Side,
    price: u64,
    qty: u64,
    seq: u64,
}

#[derive(Default)]
struct Reference {
    orders: Vec<Resting>,
    seq: u64,
}

impl Reference {
    fn best_maker(&self, taker_side: Side, limit: Option<u64>) -> Option<usize> {
        let mut best: Option<usize> = None;
        for (i, o) in self.orders.iter().enumerate() {
            if o.side == taker_side {
                continue;
            }
            if let Some(l) = limit {
                if !taker_side.crosses(l, o.price) {
                    continue;
                }
            }
            best = match best {
                None => Some(i),
                Some(b) => {
                    let ob = &self.orders[b];
                    let better_price = match taker_side {
                        Side::Buy => o.price < ob.price,
                        Side::Sell => o.price > ob.price,
                    };
                    if better_price || (o.price == ob.price && o.seq < ob.seq) {
                        Some(i)
                    } else {
                        Some(b)
                    }
                }
            };
        }
        best
    }

    fn do_match(&mut self, id: OrderId, side: Side, limit: Option<u64>, mut qty: u64, out: &mut Vec<Event>) -> u64 {
        while qty > 0 {
            let Some(i) = self.best_maker(side, limit) else { break };
            let t = qty.min(self.orders[i].qty);
            let (mid, price) = (self.orders[i].id, self.orders[i].price);
            out.push(Event::Trade { taker: id, maker: mid, price, qty: t });
            qty -= t;
            self.orders[i].qty -= t;
            if self.orders[i].qty == 0 {
                self.orders.remove(i);
                out.push(Event::Filled(mid));
            }
        }
        qty
    }

    fn rest_or_fill(&mut self, id: OrderId, side: Side, price: u64, rem: u64, out: &mut Vec<Event>) {
        if rem == 0 {
            out.push(Event::Filled(id));
        } else {
            self.seq += 1;
            self.orders.push(Resting { id, side, price, qty: rem, seq: self.seq });
            out.push(Event::Rest(id));
        }
    }

    fn exec(&mut self, cmd: &Command, out: &mut Vec<Event>) {
        match *cmd {
            Command::Limit { id, side, price, qty, tif } => match tif {
                TimeInForce::Gtc => {
                    let rem = self.do_match(id, side, Some(price), qty, out);
                    self.rest_or_fill(id, side, price, rem, out);
                }
                TimeInForce::Ioc | TimeInForce::Fok => {
                    if tif == TimeInForce::Fok {
                        let avail: u64 = self
                            .orders
                            .iter()
                            .filter(|o| o.side != side && side.crosses(price, o.price))
                            .map(|o| o.qty)
                            .sum();
                        if avail < qty {
                            out.push(Event::Reject(id));
                            return;
                        }
                    }
                    let rem = self.do_match(id, side, Some(price), qty, out);
                    out.push(if rem == 0 { Event::Filled(id) } else { Event::Cancel { id, remaining: rem } });
                }
            },
            Command::Market { id, side, qty } => {
                let rem = self.do_match(id, side, None, qty, out);
                out.push(if rem == 0 { Event::Filled(id) } else { Event::Cancel { id, remaining: rem } });
            }
            Command::Cancel { id } => match self.orders.iter().position(|o| o.id == id) {
                Some(i) => {
                    let o = self.orders.remove(i);
                    out.push(Event::Cancel { id, remaining: o.qty });
                }
                None => out.push(Event::Reject(id)),
            },
            Command::Replace { id, price, qty } => match self.orders.iter().position(|o| o.id == id) {
                None => out.push(Event::Reject(id)),
                Some(i) if self.orders[i].price == price && qty <= self.orders[i].qty => {
                    self.orders[i].qty = qty;
                    out.push(Event::Rest(id));
                }
                Some(i) => {
                    let o = self.orders.remove(i);
                    let rem = self.do_match(id, o.side, Some(price), qty, out);
                    self.rest_or_fill(id, o.side, price, rem, out);
                }
            },
            Command::Book => {
                for side in [Side::Buy, Side::Sell] {
                    let mut prices: Vec<u64> =
                        self.orders.iter().filter(|o| o.side == side).map(|o| o.price).collect();
                    prices.sort_unstable();
                    prices.dedup();
                    if side == Side::Buy {
                        prices.reverse();
                    }
                    for p in prices {
                        let at: Vec<&Resting> =
                            self.orders.iter().filter(|o| o.side == side && o.price == p).collect();
                        let qty = at.iter().map(|o| o.qty).sum();
                        let orders = at.len() as u32;
                        out.push(if side == Side::Buy {
                            Event::Bid { price: p, qty, orders }
                        } else {
                            Event::Ask { price: p, qty, orders }
                        });
                    }
                }
                out.push(Event::EndOfBook);
            }
        }
    }
}

fn random_stream(seed: u64, n: usize, price_range: u64, qty_max: u64) -> Vec<Command> {
    let mut rng = Rng(seed);
    let mut ids: Vec<OrderId> = Vec::new();
    let mut cmds = Vec::new();
    let mut counter = 0u32;
    let mut fresh = |ids: &mut Vec<OrderId>| {
        counter += 1;
        let id = OrderId::new(&format!("o{counter}")).unwrap();
        ids.push(id);
        id
    };
    for _ in 0..n {
        let side = if rng.below(2) == 0 { Side::Buy } else { Side::Sell };
        let price = 100 + rng.below(price_range);
        let qty = 1 + rng.below(qty_max);
        let cmd = match rng.below(100) {
            0..=44 => Command::Limit { id: fresh(&mut ids), side, price, qty, tif: TimeInForce::Gtc },
            45..=52 => Command::Limit { id: fresh(&mut ids), side, price, qty, tif: TimeInForce::Ioc },
            53..=58 => Command::Limit { id: fresh(&mut ids), side, price, qty, tif: TimeInForce::Fok },
            59..=64 => Command::Market { id: fresh(&mut ids), side, qty },
            65..=79 | 80..=92 => {
                // Mostly known ids (possibly dead), sometimes never-submitted.
                let id = if ids.is_empty() || rng.below(10) == 0 {
                    OrderId::new("ghost").unwrap()
                } else {
                    ids[rng.below(ids.len() as u64) as usize]
                };
                if rng.below(2) == 0 {
                    Command::Cancel { id }
                } else {
                    Command::Replace { id, price, qty }
                }
            }
            _ => Command::Book,
        };
        cmds.push(cmd);
    }
    cmds
}

fn compare(seed: u64, n: usize, price_range: u64, qty_max: u64) {
    let cmds = random_stream(seed, n, price_range, qty_max);
    let mut book = OrderBook::new();
    let mut reference = Reference::default();
    for (i, cmd) in cmds.iter().enumerate() {
        let (mut got, mut want) = (Vec::new(), Vec::new());
        book.execute(cmd, &mut got);
        reference.exec(cmd, &mut want);
        assert_eq!(got, want, "seed {seed}, command #{i}: {cmd:?}");
        assert!(!got.is_empty());
    }
    assert_eq!(book.len(), reference.orders.len());
}

#[test]
fn narrow_price_range_heavy_matching() {
    for seed in 1..=20 {
        compare(seed, 1500, 6, 10);
    }
}

#[test]
fn wide_price_range() {
    for seed in 100..=105 {
        compare(seed, 2000, 60, 1000);
    }
}

#[test]
fn huge_quantities() {
    for seed in 200..=205 {
        compare(seed, 1500, 10, 1_000_000_000);
    }
}
