package address

import (
	"reflect"
	"testing"
)

func TestParse(t *testing.T) {
	tests := []struct {
		in   string
		want []Address
	}{
		{"Real Name <user@example.com>", []Address{{"Real Name", "user@example.com"}}},
		{"user@example.com (Real Name)", []Address{{"", "user@example.com"}}},
		{`"Doe, John" <jd@x.com>`, []Address{{"Doe, John", "jd@x.com"}}},
		{"a@b.com, (c) d@e.com", []Address{{"", "a@b.com"}, {"", "d@e.com"}}},
		{"Undisclosed recipients:;", nil},
		{"grp: a@b.com, c@d.com;", []Address{{"", "a@b.com"}, {"", "c@d.com"}}},
		{"=?utf-8?B?SsO2cmc=?= <j@x.de>", []Address{{"Jörg", "j@x.de"}}},
		{"foo (c (nested)) <a@b>", []Address{{"foo", "a@b"}}},
		{"ed <a@[10.0.0.1]>", []Address{{"ed", "a@[10.0.0.1]"}}},
		{"broken <a@@b>", []Address{{"", "broken<a@@b>"}}},
		{"John Q. Public <jqp@example.com>", []Address{{"John Q. Public", "jqp@example.com"}}},
		{"Symantec Email Proxy", []Address{{"", "SymantecEmailProxy"}}},
		{`"=?utf-8?Q?x?=" <a@b>`, []Address{{"=?utf-8?Q?x?=", "a@b"}}},
		{"a <b <c@d.com> , e@f.com>, g@h.com", []Address{{"", "a<b<c@d.com>,e@f.com>"}, {"", "g@h.com"}}},
		{"John (the third) Public <jqp@x.com>", []Address{{"John   Public", "jqp@x.com"}}},
		{"", nil},
		{"bob", []Address{{"", "bob"}}},
		{`"john doe"@x.com`, []Address{{"", "john doe@x.com"}}},
		{"a.b.c@d.e.f", []Address{{"", "a.b.c@d.e.f"}}},
		{"a..b@c", []Address{{"", "a..b@c"}}},
		{"x <>", []Address{{"", "x<>"}}},
		{"x <a@b", []Address{{"", "x<a@b"}}},
		{"<a@b>", []Address{{"", "a@b"}}},
		{"g: a@b, c@d;", []Address{{"", "a@b"}, {"", "c@d"}}},
	}
	for _, tc := range tests {
		got := Parse(tc.in)
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("Parse(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
