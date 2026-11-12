"""A deliberately naive order book used as an oracle in randomized tests."""


class NaiveBook:
    def __init__(self):
        self.orders = []  # resting orders in arrival order: [id, side, price, qty]

    def _sorted_opp(self, side):
        opp = [o for o in self.orders if o[1] != side]
        if side == "BUY":
            opp.sort(key=lambda o: o[2])  # stable: FIFO within a price
        else:
            opp.sort(key=lambda o: -o[2])
        return opp

    @staticmethod
    def _crosses(side, limit, price):
        if limit is None:
            return True
        return price <= limit if side == "BUY" else price >= limit

    def _match(self, id_, side, limit, qty, out):
        for m in self._sorted_opp(side):
            if qty == 0 or not self._crosses(side, limit, m[2]):
                break
            t = min(qty, m[3])
            qty -= t
            m[3] -= t
            out.append(f"TRADE {id_} {m[0]} {m[2]} {t}")
            if m[3] == 0:
                self.orders.remove(m)
                out.append(f"FILLED {m[0]}")
        return qty

    def limit(self, id_, side, price, qty, tif=None):
        out = []
        if tif == "FOK":
            avail = sum(o[3] for o in self.orders
                        if o[1] != side and self._crosses(side, price, o[2]))
            if avail < qty:
                return [f"REJECT {id_}"]
        qty = self._match(id_, side, price, qty, out)
        if qty == 0:
            out.append(f"FILLED {id_}")
        elif tif == "IOC":
            out.append(f"CANCEL {id_} {qty}")
        else:
            self.orders.append([id_, side, price, qty])
            out.append(f"REST {id_}")
        return out

    def market(self, id_, side, qty):
        out = []
        qty = self._match(id_, side, None, qty, out)
        out.append(f"FILLED {id_}" if qty == 0 else f"CANCEL {id_} {qty}")
        return out

    def _find(self, id_):
        for o in self.orders:
            if o[0] == id_:
                return o
        return None

    def cancel(self, id_):
        o = self._find(id_)
        if o is None:
            return [f"REJECT {id_}"]
        self.orders.remove(o)
        return [f"CANCEL {id_} {o[3]}"]

    def replace(self, id_, price, qty):
        o = self._find(id_)
        if o is None:
            return [f"REJECT {id_}"]
        if price == o[2] and qty <= o[3]:
            o[3] = qty
            return [f"REST {id_}"]
        self.orders.remove(o)
        return self.limit(id_, o[1], price, qty)

    def book(self):
        out = []
        for side, label, rev in (("BUY", "BID", True), ("SELL", "ASK", False)):
            prices = sorted({o[2] for o in self.orders if o[1] == side}, reverse=rev)
            for p in prices:
                at = [o for o in self.orders if o[1] == side and o[2] == p]
                out.append(f"{label} {p} {sum(o[3] for o in at)} {len(at)}")
        out.append("--")
        return out

    def run(self, line):
        p = line.split(" ")
        if p[0] == "LIMIT":
            return self.limit(p[1], p[2], int(p[3]), int(p[4]), p[5] if len(p) == 6 else None)
        if p[0] == "MARKET":
            return self.market(p[1], p[2], int(p[3]))
        if p[0] == "CANCEL":
            return self.cancel(p[1])
        if p[0] == "REPLACE":
            return self.replace(p[1], int(p[2]), int(p[3]))
        return self.book()
