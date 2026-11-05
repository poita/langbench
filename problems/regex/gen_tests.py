#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the "regex" problem.

Hand-written edge cases live in this file as literals; random cases use fixed
seeds. Expected outputs come from running reference/main.py as a subprocess.

Cross-check: every case is also run through Python's `re` module (re.ASCII).
Fuzzing showed `re` agrees with the SPEC's semantics on this subset for every
one of ~50000 random cases, so any disagreement aborts generation. Perl's
engine differs from the SPEC only in capture values inside repeated groups
(a known Perl quirk), never in match spans, so it is not used here.

Random patterns are filtered by a backtracking budget so that no test relies
on hyper-exponential behaviour (nested nullable loops like ((.*|)+|)+x).
"""
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
sys.dont_write_bytecode = True  # keep reference/ free of __pycache__
sys.path.insert(0, os.path.join(HERE, "reference"))
import main as ref  # noqa: E402

FILES = []  # (name, [(pattern, [subjects])])


def add(name, cases):
    FILES.append((name, cases))


# ---------------------------------------------------------------------------
# Hand-written cases
# ---------------------------------------------------------------------------

add("001_empty", [
    ("", ["", "a", "abc"]),
    ("a", ["", "a", "b", "ba", "aa"]),
    ("()", ["", "x"]),
    ("(|)", ["", "x"]),
    ("a|", ["b", "a", "ba"]),
    ("|a", ["a", "ba", ""]),
    # Positional parsing: a pattern with zero subjects, and pattern/subject
    # lines that look like integers or are blank.
    ("nothing", []),
    ("12", ["12", "3", "a12"]),
    ("", ["0"]),
    ("0", ["", "0"]),
])

add("002_literals", [
    ("abc", ["abc", "xabcx", "ab", "abcabc", "ABC", "aabc"]),
    ("hello world", ["hello world", "hello  world", "say hello world!"]),
    ("a b", ["a b", "ab", "  a b  "]),
    (" ", ["", " ", "x y"]),
    (" a ", [" a ", "a", "  a  ", "a "]),
    ("a ", ["a", "a ", " a"]),
    ("z", ["aaaaaaaaaaz", "zaaaaaaaaaaa", "aaaaaaaaaa"]),
    ("aa", ["aaa", "abaa", "a"]),
    ("~!@#%&", ["x~!@#%&y", "~!@#%"]),
])

add("003_dot", [
    (".", ["", "a", "ab", " "]),
    ("a.c", ["abc", "a c", "ac", "xa.cx", "aXc"]),
    ("...", ["ab", "abc", "abcd"]),
    (".a", ["a", "ba", "aab"]),
    ("a..$", ["abc", "abcd", "ab"]),
])

add("004_classes", [
    ("[abc]", ["x", "b", "xcx", "ABC"]),
    ("[a-z]+", ["Hello World", "123", "abc def"]),
    ("[^a-z]", ["abc", "abC", "ab1", "ab "]),
    ("[a-cx-z]", ["m", "y", "bm"]),
    ("[-a]", ["b-", "a", "x"]),
    ("[a-]", ["x-", "-", "b"]),
    ("[\\-a]", ["-", "x", "a"]),
    ("[\\]]", ["]", "[", "a]"]),
    ("[\\[]", ["[", "]"]),
    ("[^\\]]", ["]", "]a", ""]),
    ("[\\\\]", ["\\", "/"]),
    ("[\\d_]+", ["abc_123x", "!!"]),
    ("[^\\s]+", ["   hello   world", "     "]),
    ("[\\D]", ["123", "12a"]),
    ("[a-a]", ["a", "b"]),
    ("[a^]+", ["^a^", "b"]),
    ("[.]", ["a.b", "ab"]),
    ("[*+?]", ["a+", "a"]),
    ("[a-c1-3]*", ["abc123x", "x"]),
    ("[^^]", ["^", "^a", "^^"]),
    ("[!-/]+", ["ab!-/,.cd", "ab"]),
    ("[\\w\\s]+", ["hello, world", ",,,"]),
    ("[^\\W]+", ["!!abc!!", "!!!"]),
    ("[A-Z][a-z]*", ["fooBar baz", "foo", "FOO"]),
    ("[0-9]{3}-[0-9]{4}", ["call 555-1234 now", "555-123"]),
])

add("005_escapes", [
    ("\\d+", ["abc123def", "abc", "0"]),
    ("\\D+", ["123abc456", "123"]),
    ("\\w+", ["  foo_bar9  ", "  !! "]),
    ("\\W+", ["foo bar", "foo"]),
    ("\\s", ["a b", "ab", " "]),
    ("\\S+", ["   abc  ", "   "]),
    ("\\.", ["a.b", "ab"]),
    ("\\\\", ["a\\b", "ab"]),
    ("\\(\\)", ["f()", "f"]),
    ("\\[\\]", ["a[]", "a"]),
    ("\\{\\}", ["{}", "{"]),
    ("\\|", ["a|b", "ab"]),
    ("\\*\\+\\?", ["*+?", "*+"]),
    ("\\^\\$", ["^$", "$^"]),
    ("\\-", ["a-b", "ab"]),
    ("\\ ", ["a b", "ab"]),
    ("\\d\\.\\d", ["3.14", "314"]),
    ("a\\|b", ["a|b", "a", "b"]),
    ("\\@\\#\\%", ["@#%", "@#"]),
])

add("006_groups_alternation", [
    ("(a)", ["a", "ba", ""]),
    ("(a)(b)(c)", ["abc", "xabcx", "ab"]),
    ("((a)(b))", ["ab", "b"]),
    ("(a|b)", ["b", "a", "c"]),
    ("a|b|c", ["c", "b", "a", "d"]),
    ("(a|ab)(c|bcd)(d*)", ["abcd", "abc", "acd"]),
    ("a|ab", ["ab", "a", "b"]),
    ("ab|a", ["ab", "a"]),
    ("(ab|a)(bc|c)?", ["abc", "ab", "a", "abcbc"]),
    ("(a|b)*c", ["ababc", "c", "ab"]),
    ("(x|y)(z|w)", ["xz", "yw", "xw", "zx"]),
    ("(|a)", ["a", ""]),
    ("(a|)", ["a", ""]),
    ("(a||b)", ["b", "a", ""]),
    ("((a|b)|(c|d))", ["c", "a", "e"]),
    ("(a)|(b)|(c)", ["c", "b", "a", "d"]),
    ("(a(b(c)))", ["abc", "ab"]),
    ("((((((a))))))", ["a", "b"]),
    ("(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)", ["abcdefghijkl", "abcdefghij"]),
])

add("007_quantifiers", [
    ("a*", ["", "aaa", "baaa", "aab"]),
    ("a+", ["", "aaa", "baaa", "b"]),
    ("a?", ["", "a", "ba"]),
    ("a*b", ["aaab", "b", "aaa", "xaab"]),
    ("a*ab", ["aaab", "ab", "a"]),
    ("a+a", ["aa", "a", "aaaa"]),
    (".*", ["", "abc"]),
    (".+", ["", "abc"]),
    (".*b", ["aaab", "abab", "aaa"]),
    (".*b.*", ["xbx", "x"]),
    ("a.*b", ["a123b456b", "ab", "ba"]),
    ("(ab)*", ["ababab", "aba", "ba", ""]),
    ("(ab)+", ["ababab", "aba", "ba", ""]),
    ("(ab)?", ["ab", "a", ""]),
    ("a?a?a?aaa", ["aaa", "aaaa", "aaaaaa", "aa"]),
    ("(a|b)*", ["abba", "abbac", "c"]),
    ("x*y*z*", ["xxyz", "zzz", "yyx", "q"]),
    ("[ab]*b", ["aaab", "baaa", "ccc"]),
    ("\\d*\\.\\d+", ["3.14", ".5", "3.", "x1.25y"]),
    ("(a*)(a*)(a*)", ["aaaa", ""]),
    ("(a+)(a+)", ["aaaa", "a"]),
    ("(.*)(.*)", ["abc"]),
    ("(.+)(.+)", ["abc", "a"]),
    ("(a*)b(a*)", ["aabaa", "b", "aa"]),
])

add("008_counted", [
    ("a{3}", ["aaa", "aa", "aaaa", "baaab"]),
    ("a{2,}", ["a", "aa", "aaaaa", "baaab"]),
    ("a{2,4}", ["a", "aa", "aaaa", "aaaaaa"]),
    ("a{0}", ["", "a"]),
    ("a{0,0}b", ["b", "ab", "a"]),
    ("a{0,}", ["aaa", "b"]),
    ("a{1}", ["a", "", "aa"]),
    ("a{1,1}a{1,1}", ["aa", "a"]),
    ("(ab){2}", ["abab", "ab", "ababab"]),
    ("(ab){1,2}c", ["ababc", "abababc", "abc", "c"]),
    ("(a|b){3}", ["abb", "ab", "abbb"]),
    ("a{2}b{2}", ["aabb", "aab", "aaabbb"]),
    ("(a{2}){2}", ["aaaa", "aaa", "aaaaa"]),
    ("(a{2,3}){2,3}", ["aaaaaaaaa", "aaa", "aaaa", "aaaaa"]),
    ("a{2,3}a{2,3}", ["aaaa", "aaaaa", "aaaaaaa", "aaa"]),
    ("(a*){3}", ["", "aa", "b"]),
    ("(a*){2,3}b", ["aab", "b", "a"]),
    ("(a?){2}", ["", "a", "aa", "aaa"]),
    ("\\d{2,3}", ["1", "12", "123", "1234"]),
    ("[a-z]{3,}\\d{1,2}", ["abc1", "ab12", "abcd123"]),
    ("x{10}", ["xxxxxxxxxx", "xxxxxxxxx", "xxxxxxxxxxx"]),
    ("(a{0,1}){0,2}a", ["a", "aa", "aaa", ""]),
    ("a{100}", ["a" * 100, "a" * 99, "a" * 101]),
    ("(ab|a){2}b", ["abab", "aab", "ab", "abb"]),
])

add("009_anchors", [
    ("^a", ["a", "ba", "ab", ""]),
    ("a$", ["a", "ba", "ab", ""]),
    ("^a$", ["a", "aa", "", "ba"]),
    ("^$", ["", "a"]),
    ("^", ["", "abc"]),
    ("$", ["", "abc"]),
    ("a^", ["a", "aa"]),
    ("$a", ["a", "aa"]),
    ("a^b", ["ab"]),
    ("a$b", ["ab"]),
    ("^^a", ["a", "ba"]),
    ("a$$", ["a", "ab"]),
    ("(^a|b)", ["a", "ba", "ab", "cb"]),
    ("(a|^b)", ["b", "ab", "cb", "a"]),
    ("a|^b", ["b", "ab", "cb", "a"]),
    ("x$|y", ["xy", "yx", "x", "zz"]),
    ("^(a|b)*$", ["abab", "abc", ""]),
    ("(^a)*b", ["aab", "ab", "b", "bab"]),
    ("(a$)?", ["a", "ab", ""]),
    ("(^)+", ["", "a"]),
    ("($){2}", ["", "a"]),
    ("^.*$", ["abc", ""]),
    ("^a.*b$", ["ab", "axxb", "axxbx", "xab"]),
    ("(a|b$)+", ["ab", "ba", "abb", "bab"]),
    ("^(^a)", ["a", "ba"]),
    ("((^)a)*", ["aa", "ba"]),
    ("$^", ["", "a"]),
    ("^$|a", ["", "a", "ba", "b"]),
    (".$", ["", "a", "ab"]),
    ("^.", ["", "a", "ab"]),
])

add("010_empty_matches", [
    ("a*", ["bbb", "", "bab"]),
    ("(a*)*", ["", "b", "aaa", "aab"]),
    ("(a*)+", ["", "b", "aaa"]),
    ("(a*)*b", ["aab", "b", "ccc", "aaac"]),
    ("(a|)*", ["aa", "", "b"]),
    ("(|a)*", ["aa", "", "b"]),
    ("(|a)*b", ["aab", "b", "a"]),
    ("(|a)+b", ["aab", "b", "a"]),
    ("()*", ["", "a"]),
    ("()+", ["", "a"]),
    ("(){3}", ["", "a"]),
    ("(a?)*", ["aa", "", "b"]),
    ("(a?)+b", ["aab", "b", "a"]),
    # Required (below-minimum) iterations are never cut short by the
    # empty-iteration rule: the second required iteration must be free to
    # match "a" after the first matched empty.
    ("(|a){2}b", ["ab", "b", "aab"]),
    ("(|a){2,}b", ["aab", "b"]),
    ("(|a){2,3}", ["aa", ""]),
    ("((|a){2}|b)+c", ["abac", "aac"]),
    ("(a?){2,}b", ["aab", "b"]),
    ("(a*)*(b*)*", ["aabb", "bbaa", ""]),
    ("(a*|b)*", ["aabab", "baa", ""]),
    ("(a|b*)*", ["aabab", "bbb", ""]),
    ("(a*b*)*", ["abab", "ba", ""]),
    ("(a*b*)+c", ["aabbc", "c", "ab"]),
    ("(a|)+", ["aa", "", "b"]),
    ("((a|)(b|))*", ["ab", "ba", ""]),
    ("(a|)*b", ["aab", "b", "aa"]),
    ("(a*)*$", ["aaa", "aab"]),
    ("^(a*)*$", ["aaa", "aab"]),
    ("(a*)*(a*)*", ["aaa", ""]),
    ("(a|b|)*c", ["abc", "c", "ab"]),
    ("(a*)*x|b", ["aaab", "b", "x"]),
    ("(|a)(|b)(|c)", ["abc", "cba", ""]),
    ("(a{0})*", ["", "a"]),
    ("(a{0,2})*b", ["aaaab", "b"]),
    ("(a*){0,2}b", ["aaab", "b"]),
    ("((a*)*)*b", ["aab", "b"]),
    ("(a*)+(b*)+c", ["ab c", "abc", "c"]),
    ("(a*|)+b", ["aab", "b"]),
    ("(a?b?)*c", ["ababc", "bac", "c"]),
    ("(.*)*x", ["aax", "x", "aa"]),
])

add("011_capture_semantics", [
    ("(a)*", ["aaa", "", "b"]),
    ("(a)+", ["aaa", "a"]),
    ("(a|(b))+", ["ba", "ab", "bb", "aa"]),
    ("(a|(b))*", ["ba", "ab", "", "b"]),
    ("((a)|b)*", ["ab", "ba", "aab", "b"]),
    ("((a)|b)+", ["ab", "ba", "b"]),
    ("(a(b)?)+", ["aba", "aab", "a", "abab"]),
    ("(a(b)?)*c", ["abac", "ac", "c"]),
    ("(a)|b", ["b", "a", "ab", "ba"]),
    ("(a)|(b)", ["b", "a"]),
    ("((a)|(b))*c", ["abc", "bac", "c"]),
    ("(a*)*", ["aaa", "b"]),
    ("(a*)+", ["aaa", "b"]),
    ("(a)*b", ["aaab", "b"]),
    ("(a*)b(c)?", ["aab", "aabc", "b"]),
    ("((a)b)*", ["abab", "aba", ""]),
    ("(a){2}", ["aa", "aaa"]),
    ("(a){0}", ["a", ""]),
    ("(a){0}(b)", ["ab", "b"]),
    ("(a)?(b)?(c)?", ["c", "ac", "abc", "bc", ""]),
    ("(a|b)(c|d)|(e)(f)", ["ef", "ac", "bd", "af"]),
    ("(x)(y)?(z)*", ["xyzz", "xzz", "x", "xy"]),
    ("((a)*)*", ["aa", ""]),
    ("((a)*b)*", ["aabb", "b", "ab"]),
    ("(a|b)*(c)?", ["abc", "ab", "c", ""]),
    ("(a|b)(a|b)(a|b)", ["aba", "abab", "ab"]),
    ("(.)*", ["abc", ""]),
    ("(.)+", ["abc"]),
    ("(.)(.)?(.)?", ["a", "ab", "abc"]),
    ("(a)(b)|(a)(c)", ["ac", "ab", "a"]),
    ("(ab|a)(b)?", ["ab", "abb", "a"]),
    ("((.)b)+", ["abcbdb", "ab"]),
    ("(a+)(a+)(a+)", ["aaaaaa", "aaa", "aa"]),
    ("^((a)|(b)|(c))+$", ["abc", "cba", "abcd"]),
    ("(((a)))*", ["aa", ""]),
    ("(a(b(c)?)?)*", ["abcab", "aab", "abc", ""]),
])

add("012_nested_quantifiers", [
    ("(a+)+b", ["aaab", "aaa", "b", "xaab"]),
    ("(a+)+", ["aaa", "", "baa"]),
    ("(a*)*b", ["aaab", "aaa"]),
    ("(a+)*b", ["aaab", "aaa", "b"]),
    ("((a|b)*c)*", ["abcbc", "c", "ab", ""]),
    ("((a|b)+c)+", ["abcbc", "c", "ab", ""]),
    ("(a{1,2}){1,2}", ["aaaa", "aaa", "a", ""]),
    ("(a{1,2}){2}b", ["aab", "aaab", "aaaab", "ab"]),
    ("((a+)b)+", ["aabab", "ab", "aab"]),
    ("(a|aa)+", ["aaaa", "aaa", "a"]),
    ("(a|aa)+b", ["aaab", "aaaa"]),
    ("(aa|a)+b", ["aaab", "aaaa"]),
    ("(a+)+(b+)+", ["aabb", "ab", "ba"]),
    ("^(a+)+$", ["aaaa", "aaab", ""]),
    ("^(a|b|ab)*$", ["abab", "abba", "abc"]),
    ("(x+x+)+y", ["xxy", "xxxy", "xy", "xxxx"]),
    ("((a*)*)*", ["aaa", ""]),
    ("(((a+)+)+)+", ["aaa", "b"]),
    ("([ab]+)+c", ["ababc", "abab"]),
    ("(\\w+\\s?)+$", ["hello world", "hello world!"]),
    ("(\\w+\\s?)*$", ["hello world", "hello world!"]),
    ("(.*)*(.*)*x", ["aax", "aa"]),
    ("((a|b)*a(a|b)*)*", ["abab", "bbb", ""]),
    ("(a?){3}(a){3}", ["aaa", "aaaaaa", "aa"]),
    ("(a|b)*(ab)+", ["abab", "ab", "ba"]),
    ("(a|b)+(ab)+", ["abab", "ab", "aab"]),
    ("(.+)+x", ["abcx", "abc"]),
    ("(a{2,3}){2,3}a", ["aaaaaaaa", "aaaaaaaaaa", "aaaa"]),
])

add("013_alternation_priority", [
    ("a|ab|abc", ["abc", "ab", "a"]),
    ("abc|ab|a", ["abc", "ab", "a"]),
    ("(a|ab)c", ["abc", "ac"]),
    ("(a|ab)(b?)", ["ab", "abb"]),
    ("(ab|a)(b?)", ["ab", "abb"]),
    (".*|a", ["a", ""]),
    ("a|.*", ["ba", "ab", ""]),
    ("(a|.)(b|.)", ["ab", "xy", "ba"]),
    ("(.|a)(.|b)", ["ab"]),
    ("(a*|b*)c", ["aac", "bbc", "c", "abc"]),
    ("(b*|a*)c", ["aac", "bbc", "c"]),
    ("(a|b|ab)(c|bcd)", ["abcd", "abc", "bcd"]),
    ("(|a)b", ["ab", "b"]),
    ("(a|)b", ["ab", "b"]),
    ("(a|)(a|)(a|)", ["aa", "a", ""]),
    ("(a*)(a|)", ["aa"]),
    ("(a|a*)b", ["aab", "ab"]),
    ("(a*|a)b", ["aab", "ab"]),
    ("(x|xx)(x|xx)(x|xx)", ["xxxxxx", "xxx", "xxxx"]),
    ("(xx|x)(xx|x)(xx|x)$", ["xxxx", "xxx", "xxxxx"]),
    ("(a|b|c|d)+", ["dcba", "e"]),
    ("(cat|category)(s)?", ["categorys", "cats"]),
    ("(category|cat)(s)?", ["categorys", "cats"]),
    ("(a)|(a)", ["a"]),
    ("(.)|(.)", ["a"]),
    ("((a)|(a))*", ["aa"]),
    ("a(b|)c|abc", ["abc", "ac"]),
    ("(ab|a)(bcd|bc|b)(d?)", ["abcd", "abd", "ab"]),
])

add("014_leftmost", [
    ("b*", ["aab", "bba", "aaa"]),
    ("aaa|b", ["baaa", "aaab", "xbaaa"]),
    ("b|aaa", ["aaab", "baaa"]),
    ("a.*b", ["xaxbxb", "bb"]),
    ("(a|b)c", ["acbc", "bcac"]),
    ("x?y", ["xy", "yxy", "zy"]),
    ("[0-9]+", ["abc12de345", "12"]),
    ("a*$", ["baa", "aab", "aaa"]),
    ("a+$", ["baa", "aab", "aaa"]),
    ("(a*)$", ["baa", "aab"]),
    ("ab*", ["bbbab", "abbb"]),
    ("(a|b)*c", ["xxabcabc", "c"]),
    ("$", ["abc"]),
    (".*", ["abc", ""]),
    ("a?", ["ba", "ab"]),
    ("z|", ["az", "za", ""]),
    ("|z", ["az", "za"]),
    ("(z|)", ["az", "za"]),
])

add("015_backtracking_classic", [
    ("^(.*)(.*)$", ["abcdef", ""]),
    ("^(.*)-(.*)$", ["a-b-c", "abc", "-", "a-b-c-d-e"]),
    ("^(.+)-(.+)$", ["a-b-c", "a-", "-b", "ab-cd"]),
    ("(\\w+)@(\\w+)\\.com", ["mail me at foo@bar.com now", "foo@bar.org", "@bar.com", "a@b.com"]),
    ("<(.*)>", ["<a><b>", "<>", "<a", "a>"]),
    ("<(.*)>(.*)", ["<a><b>"]),
    ("<([^>]*)>", ["<a><b>", "<>"]),
    ("a.*b.*c", ["aXXbYYcZZ", "abc", "acb", "aaabbbccc"]),
    ("(a|b)*ab", ["ababab", "ab", "ba"]),
    ("([a-z]+)([0-9]+)", ["abc123", "abc123def456", "ab1c2"]),
    ("([a-z]*)([a-z]*)", ["abc"]),
    ("(\\d+)(\\d+)", ["12345", "1"]),
    ("(\\d+)\\.(\\d+)", ["3.14.15", "1.2"]),
    ("(.*)(\\d+)", ["abc123", "123"]),
    ("^(a+)(a+)(a+)$", ["aaaaa", "aaa", "aa"]),
    ("^(a*)(a*)(a*)$", ["aaa"]),
    ("(a+)b(a+)", ["aabaa", "aabab", "ba"]),
    ("(x*)(x*)(x*)y", ["xxxy", "y", "xxx"]),
    ("([ab]*)(b+)", ["ababb", "a", "bbb"]),
    ("(\\S+)\\s+(\\S+)", ["hello   world", "hello", " a b "]),
    ("([^,]*),([^,]*)", ["a,b,c", ",", "abc"]),
    ("(.*),(.*)", ["a,b,c", ",", "abc"]),
    ("(.+),(.+)", ["a,b,c", ",", "a,"]),
])

add("016_misc_tricky", [
    ("(a|b)c|ad", ["ad", "ac", "bc", "bd"]),
    ("a(b|c)*d", ["abcbcd", "ad", "abd", "abc"]),
    ("(ab)*c", ["ababc", "abac", "c"]),
    ("(a|b)?c", ["c", "ac", "bc", "abc"]),
    ("([a-z]+)\\s*=\\s*([0-9]+)", ["x = 10", "abc=5", "x=", "=5"]),
    ("^\\s*$", ["", "   ", " a "]),
    ("^\\d{4}-\\d{2}-\\d{2}$", ["2024-01-15", "2024-1-15", "12024-01-15"]),
    ("(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})", ["ip 192.168.1.1 ok", "1.2.3", "1234.1.1.1"]),
    ("([A-Z][a-z]+) ([A-Z][a-z]+)", ["John Smith", "john smith", "Mr John Smith"]),
    ("(a|b)(c|d)(e|f)", ["ace", "bdf", "adf", "acf"]),
    ("a{2}|b{2}", ["ab", "aab", "abb"]),
    ("(a{2}|b{2})+", ["aabb", "aab", "abab"]),
    ("([^ ]+) ([^ ]+)", ["a b c", "abc"]),
    ("x(y?)(z?)x", ["xx", "xyx", "xzx", "xyzx", "xzyx"]),
    ("(a)(b)?(c)?(d)?(e)?(f)?(g)?(h)?(i)?(j)?", ["abcdefghij", "a", "ace"]),
    ("a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p|q|r|s|t|u|v|w|x|y|z", ["Z", "z", "12k"]),
    ("(((a)))", ["a"]),
    ("(a)(((b)))((c))", ["abc"]),
    ("[a-z]+@[a-z]+\\.(com|org|net)", ["x@y.net", "x@y.com", "x@y.io"]),
    ("(\\w+):(\\d+)", ["host:8080", "host:", ":80"]),
    ("^(\\+|-)?\\d+(\\.\\d+)?$", ["+3.5", "-7", "3.", "abc", "3.5.1"]),
    ("[\\^a]", ["^", "a", "b"]),
    ("[a\\^]", ["^", "a", "b"]),
    ("\\$\\d+\\.\\d{2}", ["cost: $12.50", "$12.5"]),
    ("(\\()(\\))", ["()", "("]),
    ("(\\[)(\\])", ["[]", "["]),
])

# ---------------------------------------------------------------------------
# Random pattern generator
# ---------------------------------------------------------------------------

def make_gen(rng, alpha, class_pool, group_prob, max_depth, max_pieces):
    def atom(depth):
        r = rng.random()
        if r < 0.35:
            return rng.choice(alpha)
        if r < 0.45:
            return "."
        if r < 0.55:
            return rng.choice(class_pool)
        if r < 0.62:
            return rng.choice(["^", "$"])
        if depth > 0 and rng.random() < group_prob:
            return "(" + alt(depth - 1) + ")"
        return rng.choice(alpha)

    def quant():
        r = rng.random()
        if r < 0.5:
            return ""
        if r < 0.62:
            return "*"
        if r < 0.74:
            return "+"
        if r < 0.86:
            return "?"
        a = rng.randint(0, 3)
        b = a + rng.randint(0, 3)
        return rng.choice(["{%d}" % a, "{%d,}" % a, "{%d,%d}" % (a, b)])

    def seq(depth):
        out = []
        for _ in range(rng.randint(0, max_pieces)):
            a = atom(depth)
            q = quant() if a not in ("^", "$") else ""
            out.append(a + q)
        return "".join(out)

    def alt(depth):
        return "|".join(seq(depth) for _ in range(rng.randint(1, 3)))

    return lambda: alt(max_depth)


def escape_literal(c):
    return "\\" + c if c in "\\.[]()|*+?{}^$" else c


def random_cases(seed, count, alpha, class_pool, group_prob=1.0, max_depth=2, max_pieces=3,
                 nsub=(3, 6), sublen=(0, 8), budget=20000):
    rng = random.Random(seed)
    gen = make_gen(rng, [escape_literal(c) for c in alpha], class_pool, group_prob, max_depth, max_pieces)
    cases = []
    while len(cases) < count:
        pat = gen()
        if len(pat) > 250:
            continue
        subs = ["".join(rng.choice(alpha) for _ in range(rng.randint(*sublen)))
                for _ in range(rng.randint(*nsub))]
        rx = ref.Regex(pat)
        rx.budget = budget
        try:
            for s in subs:
                rx.search(s)
        except ref.BudgetExceeded:
            continue
        cases.append((pat, subs))
    return cases


AB_CLASSES = ["[ab]", "[^a]", "[a-b]", "[^b]", "\\w", "\\W"]
MIXED_CLASSES = ["[ab]", "[^a]", "[a-c]", "\\w", "\\d", "\\s", "\\W", "\\D", "\\S",
                 "[\\d_]", "[^\\w ]", "[a-c1-3]", "[ -/]", "[^\\s]", "[\\-.]", "[\\]a]"]

add("017_fuzz_ab", random_cases(101, 300, "ab", AB_CLASSES))
add("018_fuzz_mixed", random_cases(202, 300, "ab1 _.", MIXED_CLASSES))
add("019_fuzz_deep", random_cases(303, 150, "abc", MIXED_CLASSES, max_depth=4, max_pieces=4, sublen=(0, 14)))
add("020_fuzz_flat", random_cases(404, 300, "abcd", MIXED_CLASSES, group_prob=0.3, max_depth=1,
                                  max_pieces=6, sublen=(0, 20)))
add("021_fuzz_punct", random_cases(505, 250, "a.-]^\\ ", MIXED_CLASSES, sublen=(0, 10)))

# ---------------------------------------------------------------------------
# Realistic patterns over generated text
# ---------------------------------------------------------------------------

def realistic_cases(seed, n_subjects, extra_len=0):
    rng = random.Random(seed)
    words = ["alpha", "beta", "gamma", "delta", "foo", "bar", "baz", "qux", "lorem", "ipsum",
             "error", "warn", "info", "debug", "user", "admin", "root", "guest"]
    tlds = ["com", "org", "net", "io", "co.uk"]

    def word():
        return rng.choice(words)

    def email():
        return "%s%s@%s.%s" % (word(), rng.choice(["", ".", "_", "42"]), word(), rng.choice(tlds))

    def ip():
        return ".".join(str(rng.randint(0, 299)) for _ in range(4))

    def date():
        return "%04d-%02d-%02d" % (rng.randint(1900, 2099), rng.randint(0, 13), rng.randint(0, 32))

    def number():
        return rng.choice(["", "-", "+"]) + str(rng.randint(0, 99999)) + rng.choice(["", ".5", ".25", "."])

    def token():
        r = rng.random()
        if r < 0.4:
            return word()
        if r < 0.55:
            return email()
        if r < 0.65:
            return ip()
        if r < 0.75:
            return date()
        if r < 0.85:
            return number()
        if r < 0.92:
            return "%s=%s" % (word(), rng.choice([word(), str(rng.randint(0, 9999)), '"' + word() + '"']))
        return rng.choice(["!", "?", ",", ";", "(", ")", "[x]", "{y}", "a*b", "c+d", "$5", "^^"])

    def line():
        n = rng.randint(0, 12)
        s = " ".join(token() for _ in range(n))
        if extra_len:
            s += " " + " ".join(token() for _ in range(extra_len))
        return s

    subjects = [line() for _ in range(n_subjects)]
    patterns = [
        "[a-z0-9_.]+@[a-z0-9]+\\.[a-z.]+",
        "([a-z0-9_.]+)@([a-z0-9]+)\\.([a-z]+)(\\.[a-z]+)?",
        "(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})",
        "^(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})$",
        "(\\d{4})-(\\d{2})-(\\d{2})",
        "(19|20)(\\d{2})-(0[1-9]|1[0-2])-(0[1-9]|[12]\\d|3[01])",
        "(\\+|-)?(\\d+)(\\.(\\d*))?",
        "(\\w+)=(\"([^\"]*)\"|\\w+)",
        "(error|warn|info|debug)",
        "^(error|warn|info|debug)",
        "(error|warn|info|debug)$",
        "(alpha|beta|gamma|delta) (foo|bar|baz|qux)",
        "\\$\\d+",
        "\\(|\\)|\\[|\\]|\\{|\\}",
        "(\\S+)\\s+(\\S+)\\s+(\\S+)",
        "^(.*) (.*)$",
        "^(.*)(user|admin|root)(.*)$",
        "([a-z]+)(\\d+)",
        "a\\*b|c\\+d",
        "[^a-z ]+",
        "(\\w+)\\.(\\w+)",
        "^\\s*$",
        "(\\w+) \\w+ (\\w+)",
        "^([^ ]+ ){3}",
        "\\d{3,}",
        "(x|y|z)+",
        "([aeiou])([aeiou])",
        "ipsum|lorem",
    ]
    return [(p, subjects) for p in patterns]


add("022_realistic", realistic_cases(606, 200))

# ---------------------------------------------------------------------------
# Long subjects, many subjects, counted-repeat stress
# ---------------------------------------------------------------------------

def long_subjects(seed):
    """Subjects near the 10000-character limit, paired only with patterns that
    behave linearly on them (quadratic scans live in 028 at smaller sizes)."""
    rng = random.Random(seed)
    alpha = "abcdefghij0123456789 "
    rand = ["".join(rng.choice(alpha) for _ in range(rng.randint(5000, 10000))) for _ in range(8)]
    linear_on_random = [
        "x",
        "\\d{6}",
        "[a-j]{8}",
        "(\\d+) (\\d+)",
        "^.*$",
        ".*",
        "^(a|b)*$",
        "(.)*$",
        "\\s+\\d\\s+",
        "(a|b|c|d|e)(f|g|h|i|j)(0|1|2|3|4)",
        "^([a-j0-9]*\\s){5}",
        "b|c|d|e|f|g|h|i|j",
        "[a-j]+\\d+[a-j]+\\d+ ",
        "(\\S+\\s+){5}\\S+",
        "(\\w+\\s*)*$",
        "([a-j]+)(\\d+)( +)([a-j]+)",
        "  +",
    ]
    cases = [(p, rand) for p in linear_on_random]
    cases += [
        ("x", ["x" * 10000, "a" * 10000, "a" * 9999 + "x"]),
        ("needle", ["x" * 9994 + "needle", "needle" + "x" * 9994, "x" * 10000]),
        ("^a*$", ["a" * 10000, "a" * 9999 + "b", ""]),
        ("^\\s*$", [" " * 10000, " " * 9999 + "x"]),
        (".*", ["x" * 10000]),
        ("(a*)*b", ["a" * 9999 + "b"]),
        ("^(a|b)*$", ["a" * 10000, "ab" * 5000, "ab" * 4999 + "c"]),
        ("^(ab)*$", ["ab" * 5000, "ab" * 4999 + "a"]),
        ("^(ab)+$", ["ab" * 5000, "ab" * 4999 + "a", ""]),
        ("(.)*$", ["x" * 10000]),
        ("a+$", ["a" * 10000]),
        (".*b", ["ab" * 5000]),
        ("(.*)b$", ["ab" * 5000]),
        ("(\\S+\\s+){5}\\S+", ["word " * 2000, "word " * 3]),
        ("(a|b)+(c|d)+", ["ab" * 4000 + "cd" * 1000]),
        ("^(\\w+ )*END$", ["word " * 1999 + "END", "word " * 2000]),
        ("(0|1|2|3|4|5|6|7|8|9)+", ["0123456789" * 1000]),
        ("[a-j]*\\d", ["j" * 9999 + "1"]),
    ]
    return cases


add("023_long_subjects", long_subjects(707))


def many_subjects(seed):
    rng = random.Random(seed)
    alpha = "ab01 xy"
    subs = ["".join(rng.choice(alpha) for _ in range(rng.randint(0, 60))) for _ in range(15000)]
    patterns = ["^(a|b)+$", "(\\d+)(\\s+)(\\d+)", "x.*y", "(ab|ba)*(01|10)+", "^$", "([^ ]+) ([^ ]+) ([^ ]+)"]
    return [(p, subs) for p in patterns]


add("024_many_subjects", many_subjects(808))


def counted_stress():
    """Large counted quantifiers; failing subjects are chosen so that they fail
    fast rather than enumerating exponentially many partitions."""
    return [
        ("a{50}", ["a" * 49, "a" * 50, "b" * 20 + "a" * 51, "a" * 30 + "b" + "a" * 50]),
        ("(ab){40,60}", ["ab" * 39, "ab" * 40, "ab" * 100, "x" + "ab" * 60 + "y"]),
        ("(a{10}){10}", ["a" * 100, "a" * 99, "b" * 5 + "a" * 150]),
        ("(a{2,3}){30,40}b", ["a" * 100 + "b", "a" * 10 + "b", "a" * 120 + "b", "a" * 20 + "b" + "a" * 40]),
        ("(a|aa){20,30}$", ["a" * 25, "a" * 30, "a" * 19, "a" * 31]),
        ("\\d{5,10}-\\d{5,10}", ["12345678901-12345", "1234-56789", "x123456-1234567890y"]),
        ("([a-z]{2,4}\\d{1,2}){3,5}", ["ab1cd22efg3", "ab1cd2", "xyz12abc3de4fgh56ijk7"]),
        ("(a?){16}a{16}", ["a" * 16, "a" * 15, "a" * 40]),
        ("^(x{3}){0,100}$", ["x" * 300, "x" * 299, "x" * 303]),
        ("(a*){100}b", ["a" * 50 + "b", "b", "xb", "c"]),
        ("((a{3}){3}){3}", ["a" * 27, "a" * 26, "a" * 80]),
        ("(a{1,3}b?){10,20}c", ["aab" * 12 + "c", "aab" * 9 + "c", "a" * 45 + "c", "ab" * 5 + "c"]),
        ("(\\w{0,2}){100}$", ["w" * 150, "w" * 200, "!"]),
        ("[a-z]{100}", ["z" * 100, "z" * 99, "1" + "z" * 100]),
        ("(a{0,1}){100}b", ["a" * 100 + "b", "a" * 50 + "b", "c"]),
        ("a{100}a{100}a{100}", ["a" * 300, "a" * 299]),
        ("(ab|cd){50}", ["abcd" * 25, "abcd" * 24 + "ab", "abcd" * 24 + "ac"]),
        ("(a{2}|a{3}){10}$", ["a" * 25, "a" * 20, "a" * 30, "a" * 19]),
    ]


add("025_counted_stress", counted_stress())

# ---------------------------------------------------------------------------
# Pathological but bounded backtracking (each file needs well under 20M
# backtracks in total; sizes were chosen by measuring the reference)
# ---------------------------------------------------------------------------

add("026_pathological_nested", [
    ("(a*)*b", ["a" * 17, "a" * 17 + "b"]),
    ("(a+)+b", ["a" * 17, "a" * 17 + "b"]),
    ("^(a+)+$", ["a" * 19 + "b", "a" * 19]),
    ("((a*)*)*b", ["a" * 9, "a" * 9 + "b"]),
    ("(a?){16}a{16}", ["a" * 16, "a" * 15]),
    ("(.*a){10}b", ["a" * 16]),
    ("^(\\w+\\s?)*$", ["word " * 4 + "word!", "word " * 4 + "word"]),
    ("(a?){8}(b?){8}c", ["a" * 8 + "b" * 8]),
    ("(a*b*)*c", ["ab" * 8]),
    ("((a|b)*a(a|b)*)*c", ["ab" * 6]),
])

add("027_pathological_alternation", [
    ("(a|aa)+c", ["a" * 22, "a" * 22 + "c"]),
    ("(aa|a)+c", ["a" * 22, "a" * 22 + "c"]),
    ("(x+x+)+y", ["x" * 16, "x" * 16 + "y"]),
    ("(a|a)*b", ["a" * 17, "a" * 17 + "b"]),
    ("(a|b|ab|ba)*c", ["ab" * 10, "ab" * 10 + "c"]),
    ("([ab]+)+[cd]", ["ab" * 8]),
    ("(a|b|c)*(a|b|c)*(a|b|c)*(a|b|c)*x", ["abc" * 9]),
    ("(.*)(.*)(.*)(.*)(.*)x", ["abcdefgh" * 3]),
    ("(.+)(.+)(.+)(.+)(.+)(.+)x", ["abcdefgh" * 3]),
    ("(a*)(a*)(a*)(a*)(a*)(a*)b", ["a" * 18]),
    ("(a|ab)(c|bcd)(d*)" * 5, ["abcd" * 5, "abcd" * 4 + "abcx"]),
    ("(a|ab|abc|abcd)+$", ["abcd" * 15 + "e"]),
    ("(ab|a)(bc|c|b)*d$", ["abc" * 14 + "e"]),
    ("(a|b|ab)*(ab|b)+$", ["ab" * 9 + "c"]),
])

add("028_pathological_quadratic", [
    ("a*b", ["a" * 1200, "a" * 1200 + "b"]),
    ("a+b", ["a" * 1200]),
    (".*x", ["y" * 1200]),
    ("(\\w+)@", ["word" * 300]),
    ("\\w+\\d", ["a" * 1200]),
    ("[a-z]+[0-9]", ["z" * 1200 + "1", "z" * 1200]),
    (".*a.*b.*c", ["a" * 30 + "b" * 30]),
    ("(a|b)*c", ["ab" * 600]),
    ("^(a|b)*c", ["ab" * 5000]),
    ("(\\d+)\\.(\\d+)\\.(\\d+)\\.(\\d+)", ["123456789" * 120]),
    ("(.*),(.*),(.*)", ["a,b" * 400]),
    ("(.*)=(.*)", ["k" * 1200]),
])

# ---------------------------------------------------------------------------
# Big mixed files
# ---------------------------------------------------------------------------

add("029_big_mixed", realistic_cases(909, 400, extra_len=10)
    + random_cases(910, 200, "abc ", MIXED_CLASSES, nsub=(20, 40), sublen=(0, 40)))


def big_text(seed):
    rng = random.Random(seed)
    words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "2024", "3.14",
             "foo@bar.com", "x=1", "(y)", "z*", "END", "start", "MID"]
    subs = []
    for _ in range(60):
        subs.append(" ".join(rng.choice(words) for _ in range(rng.randint(300, 1000))))
    patterns = [
        "fox jumps over",
        "(\\w+) (\\w+) (\\w+) (\\w+) (\\w+)$",
        "^(\\w+ )*END",
        "(\\d+\\.\\d+)",
        "([a-z]+)@([a-z]+)\\.com",
        "(quick|brown|lazy) (fox|dog)",
        "^.*MID.*$",
        "(the|a) (quick|slow|brown)",
        "z\\*",
        "\\(y\\)",
    ]
    return [(p, subs) for p in patterns]


add("030_big_text", big_text(1010))

# ---------------------------------------------------------------------------
# Emit and verify
# ---------------------------------------------------------------------------

def encode(cases):
    lines = [str(len(cases))]
    for pat, subs in cases:
        lines.append(pat)
        lines.append(str(len(subs)))
        lines.extend(subs)
    return "\n".join(lines) + "\n"


def re_expected(cases):
    """Independent expected output from Python's re, in the SPEC's output format."""
    out = []
    for pat, subs in cases:
        c = re.compile(pat, re.ASCII)
        for s in subs:
            m = c.search(s)
            if m is None:
                out.append("no")
                continue
            parts = ["match %d %d" % m.span()]
            for g in range(1, c.groups + 1):
                a, b = m.span(g)
                parts.append("-" if a < 0 else "%d,%d" % (a, b))
            out.append("|".join(parts))
    return out


# Per-search backtrack cap: a case above this is a generator mistake (it would
# take the reference many seconds), so generation aborts rather than hangs.
CASE_BUDGET = 3_000_000


def measure(name, cases):
    """Total backtracks the reference needs for a file; aborts on runaway cases."""
    total = 0
    for pat, subs in cases:
        rx = ref.Regex(pat)
        rx.budget = CASE_BUDGET
        for s in subs:
            try:
                rx.search(s)
            except ref.BudgetExceeded:
                sys.exit("runaway case in %s: pattern %r on subject of length %d" % (name, pat, len(s)))
            total += rx.backtracks
    return total


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(TESTS, f))
    total = 0
    for name, cases in FILES:
        for pat, subs in cases:
            assert len(pat) <= 300, (name, pat)
            assert all(len(s) <= 10000 for s in subs), name
            assert all(32 <= ord(ch) <= 126 for ch in pat), (name, pat)
            assert all(32 <= ord(ch) <= 126 for s in subs for ch in s), name
        data = encode(cases)
        backtracks = measure(name, cases)
        in_path = os.path.join(TESTS, name + ".in")
        with open(in_path, "w") as f:
            f.write(data)
        proc = subprocess.run([sys.executable, os.path.join(HERE, "reference", "main.py")],
                              input=data.encode(), capture_output=True, check=True)
        actual = proc.stdout.decode()
        with open(os.path.join(TESTS, name + ".out"), "w") as f:
            f.write(actual)
        expected = re_expected(cases)
        got = actual.rstrip("\n").split("\n")
        print("%-32s %3d patterns %6d subjects %8d bytes %10d backtracks" % (
            name, len(cases), len(got), len(data), backtracks))
        sys.stdout.flush()
        if got != expected:
            for i, (a, b) in enumerate(zip(got, expected)):
                if a != b:
                    print("CROSS-CHECK MISMATCH in %s line %d: ref=%r re=%r" % (name, i + 1, a, b))
                    break
            sys.exit(1)
        total += len(data)
    print("total input bytes:", total)


if __name__ == "__main__":
    main()
