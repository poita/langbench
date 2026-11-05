#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `spreadsheet` problem.

Every test is either an embedded literal (hand-written edge cases) or
produced by a seeded generator, so re-running this script reproduces the
suite exactly. Expected outputs come from reference/main.py run as a
subprocess. The script then cross-checks the suite three ways:

- random-workbook tests are replayed through an independent oracle that
  rebuilds the whole sheet from scratch after every command (lazy memoised
  evaluation, no incremental bookkeeping) and must agree line for line;
- the structured performance tests are checked against closed-form values
  computed directly in this script;
- every number the reference displayed is checked to not be an exact
  rounding tie at 10 significant digits (so any correctly rounded printf
  agrees), and the reference's hand-rolled formatter is compared with
  Python's C-compatible '%.10g' on random doubles.
"""
import importlib.util
import io
import os
import random
import subprocess
import sys
from decimal import Decimal

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')

spec = importlib.util.spec_from_file_location('ref', REF)
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)

cases = []          # (name, input_text)
oracle_names = set()   # tests replayed through the from-scratch oracle
analytic = {}       # name -> expected output text computed directly


def add(name, text, oracle=False):
    if not text.endswith('\n'):
        text += '\n'
    cases.append((name, text))
    if oracle:
        oracle_names.add(name)


def cn(row, col):
    return ref.col_name(col) + str(row)


# ---------------------------------------------------------------------------
# Hand-written edge cases
# ---------------------------------------------------------------------------

add('empty_sheet', 'get A1\ndump\nget ZZ9999\nset A1 0\nget A1\ndump\nclear A1\ndump\n')

add('numbers_basic', '''set A1 5
set A2 -3
set A3 4.50
set A4 007
set A5 -0
set A6 0.5
set A7 -3.25
set A8 123456789012345
set A9 100000000000000000000
get A1
get A2
get A3
get A4
get A5
get A6
get A7
get A8
get A9
dump
''')

add('strings_basic', '''set A1 "hello"
set A2 ""
set A3 "  spaced  out  "
set A4 "12"
set A5 "=A1+1"
set A6 "#DIV/0!"
get A1
get A2
get A3
get A4
get A5
get A6
get A7
dump
''')

add('formula_simple', '''set A1 10
set A2 32
set A3 =A1+A2
set A4 =A3*2
set A5 =A4/8
set A6 =A5-A1
get A3
get A4
get A5
get A6
set A1 20
get A3
get A4
get A5
get A6
dump
''')

add('precedence', '''set A1 =1+2*3
set A2 =(1+2)*3
set A3 =10-2-3
set A4 =100/10/2
set A5 =2*3+4*5
set A6 =1+2&3
set A7 =1<2+3
set A8 =1+1=2
set A9 =2*3=1+5
set A10 ="a"&"b"="ab"
set A11 =1<2<3
set A12 =3>2>1
set A13 =(1<2)+(2<3)
set A14 =2+3*4-5/5
set A15 =((2))
set A16 =1&2+3
set A17 =1=1&1
set A18 =10/4*2
dump
''')

add('unary_minus', '''set B1 7
set B2 "s"
set A1 =-5
set A2 =--5
set A3 =-B1
set A4 =2*-3
set A5 =-(1+2)
set A6 =-B2
set A7 =-B3
set A8 =-B1*-B1
set A9 =1--1
set A10 =-2-3
set A11 =-0.5*0
set A12 =1/-B3
dump
''')

add('number_format', '''set A1 =1/3
set A2 =2/3
set A3 =1000000000000000
set A4 =100000000000000
set A5 =999999999999999
set A6 =1000000000000000+0.5
set A7 =0.00001
set A8 =0.0001
set A9 =0.000123456789012
set A10 =123456.789
set A11 =12345678901.5
set A12 =1234567890.5
set A13 =1234567890.6
set A14 =9999999999.7
set A15 =-2.5
set A16 =1/8
set A17 =22/7
set A18 =10000000000*10000000000
set A19 =123456789*1000000000
set A20 =0.1+0.2
set A21 =1/1024/1024
set A22 =-1/3
set A23 =2/3&""
set A24 =100/3
set A25 =1000000/7
set A26 =99999.99999
set A27 =0.000099999999995
set A28 =1234567890123456
set A29 =-1000000000000000
set A30 =123456789.12345
set A31 =0.5+0.25+0.125
set A32 =1/7
set A33 =1/70000
set A34 =1/700000
set A35 =3000000000000000000000000000000
set A36 =-0.00000123
set A37 =2500000000.25
set A38 =2500000000.75
set A39 =1200000000.4
set A40 =-1200000000.4
set A41 =12000000000.4
set A42 =1200000000.4&""
set A43 =-1.5*1000000000000000
set A44 =2.5/10000000000
set A45 =1234567.891
set A46 =0.0001234
set A47 =1234567890.4
set A48 =-123456789012345
dump
''')

add('strings_concat', '''set A1 "ab"
set A2 =A1&"cd"
set A3 =A1&1
set A4 =1&2
set A5 =B1&B2
set A6 ="x"&1/3
set A7 =1+2&3
set A8 ="a"&B1
set A9 =("a"&"b")="ab"
set A10 =A2&A2&A2
set A11 =-1.5&"!"
set A12 =""&""
set A13 ="n="&(2+2)
set A14 =A5&"|"
set A15 =1/0&"x"
set A16 ="x"&1/0
dump
''')

add('comparisons', '''set A1 "abc"
set A2 "abd"
set A3 "ab"
set A4 "B"
set A5 "a"
set A6 5
set B1 =A1<A2
set B2 =A3<A1
set B3 =A4<A5
set B4 =A1=A1
set B5 =A1<>A2
set B6 =A5=1
set B7 =A5<>1
set B8 =A5<1
set B9 =1>A5
set B10 =1<=A5
set B11 =1>=A5
set B12 =Z1=Z2
set B13 =Z1=0
set B14 =Z1=""
set B15 =Z1<""
set B16 =Z1<>""
set B17 =1.0=1
set B18 =0.1+0.2=0.3
set B19 =A6>=5
set B20 =A6>5
set B21 =A6<=5
set B22 =-1<Z1
set B23 =A1="abc"
set B24 =A1<>"abc"
set B25 =A1>"ABC"
set B26 ="" <""
set B27 =""<="a"
set B28 =A6=A6
set B29 =Z1<0
set B30 =1/0=1
set B31 =1=1/0
dump
''')

add('if_function', '''set A1 5
set A2 "yes"
set B1 =IF(1,10,20)
set B2 =IF(0,10,20)
set B3 =IF("a",1,2)
set B4 =IF(1/0,1,2)
set B5 =IF(1,5,1/0)
set B6 =IF(0,1/0,"no")
set B7 =IF(A1>5,"big","small")
set B8 =IF(Z1,1,2)
set B9 =IF(A1,IF(A1>3,"gt3","le3"),"zero")
set B10 =IF(1,Z1,7)
set B11 =IF(1,"",2)
set B12 =IF(A1=5,A2,"no")
set B13 =IF(A1-5,1,2)
set B14 =IF(-0.5,1,2)
set B15 =IF(A1>1,A1*2,A1/2)+1
set B16 =IF(A1,A2,0)&"!"
set B17 =IF(A2="yes",1,0)
set B18 =IF(A2,1,0)
set B19 =IF(IF(1,0,1),"a","b")
set B20 =IF(1,1/0,2)
set B21 =IF(0,"x",Z1)
get B11
dump
''')

add('ranges_aggregates', '''set A1 1
set A2 2
set A3 3
set A4 "text"
set A6 10
set B1 4
set B2 5
set B3 6
set C1 =SUM(A1:A3)
set C2 =SUM(A1:B3)
set C3 =SUM(B3:A1)
set C4 =SUM(A1:A6)
set C5 =COUNT(A1:A6)
set C6 =AVG(A1:A6)
set C7 =MIN(A1:B3)
set C8 =MAX(A1:B3)
set C9 =SUM(1,2,3)
set C10 =SUM(A1:A3,B1:B3,100)
set C11 =SUM("a")
set C12 =SUM(A4)
set C13 =SUM(A5)
set C14 =COUNT(A5)
set C15 =AVG(A5:A5)
set C16 =MIN(A5:A5)
set C17 =MAX(A5)
set C18 =SUM(A1:A3,1/0)
set C19 =SUM(1/0,A1:A3)
set C20 =COUNT(A1:A3,"x")
set C21 =AVG(1,2,4)
set C22 =MIN(3,1,2)
set C23 =MAX(3,-1,A1:B3)
set C24 =SUM(A1:A1)
set C25 =SUM(D1:E5)
set C26 =AVG(D1:E5)
set C27 =COUNT(A1:C3)
set C28 =SUM(SUM(A1:A3),SUM(B1:B3))
set C30 =MIN(A6,B1:B3)
set C31 =SUM(A1:A3)/COUNT(A1:A3)
set C32 =AVG(A1:A3)=C31
dump
''')

add('errors_propagate', '''set A1 =1/0
set A2 ="a"+1
set A3 =A1+A2
set A4 =A2+A1
set A5 ="a"+1/0
set A6 =1/0+"a"
set A7 =-A1
set A8 =A1&"x"
set A9 =IF(A1,1,2)
set A10 =A3*0
set A11 =0/0
set A12 =1/A13
set A13 0
set A14 =SUM(A1:A2)
set A15 =SUM(A2:A2,A1)
set A16 =SUM(B1:B3)
set B1 10000000000
set B2 =B1*B1
set B3 =B2*B2
set B4 =B3*B3
set B5 =B4*B4
set B6 =B5*B5
set B7 =B6+1
set B8 =B6-B6
set B9 =-B5-B5
set B10 =SUM(B5,B5)
set B11 =AVG(B5,B5)
set B12 =B5*10
set B13 =B5/0.0000000001
set B14 =1/B5
set B15 =B5-B5
set B16 =B5>B4
set B17 ="5"+1
set B18 ="5"*"5"
set B19 =A9
set B20 ="a"<1
set B21 =(1/0)=(1/0)
set B22 =IF(A2=A1,1,2)
dump
''')

add('invalid_refs', '''set A1 =A0
set A2 =AAA1
set A3 =A10000
set A4 =A01
set A5 =SUM(A0:B2)
set A6 =IF(1,5,A0)
set A7 =ZZ9999
set A8 =A9999
set A9 =A1
set A10 =A10+A0
set A11 =A10
set A12 =1+ZZ0
set A13 =SUM(A9999:ZZ9999)
set A14 =ZZZ1&"x"
set A15 =IF(A0,1,2)
dump
''')

add('empty_cells', '''set B1 =A1
set B2 =A1&"x"
set B3 =A1=0
set B4 =SUM(A1:A3)
set B5 =COUNT(A1:A3)
set B6 =AVG(A1:A3)
set B7 =IF(A1,1,2)
set B8 =-A1
set B9 =A1*5+1
set B10 =A1/1
set B11 =1/A1
set B12 =MIN(A1:A3)
set B13 =MAX(A1:A3)
set B14 =A1&A2&A3
set B15 =IF(1,A1,2)
set B16 =A1<A2
set B17 =A1<>A2
set B18 =SUM(A1,A2,A3)
set B19 =(A1)&"x"
set B20 =-A1&"x"
set B21 =IF(1,A1,2)&"x"
set B22 =(A1)=""
set B23 =IF(1,A1,2)=""
set B24 =COUNT(IF(1,A1,2))
set B25 =COUNT((A1))
set B26 =SUM(IF(1,A1,2),1)
set B27 =(A1)
set B28 =-A1=""
set A1 5
get B1
get B2
get B3
get B4
get B7
get B15
get B19
get B20
get B21
clear A1
get B1
get B2
get B3
get B4
get B7
get B15
clear A2
clear ZZ9999
dump
''')

add('cycles_basic', '''set A1 =A1
get A1
set A1 =A1+1
get A1
set A1 1
get A1
set B1 =B2
set B2 =B1
set B3 =B1+B2
get B1
get B2
get B3
set B2 5
get B1
get B2
get B3
set C1 =C2
set C2 =C3
set C3 =C1
set C4 =C3*2
set C5 =IF(0,C1,7)
set C6 =IF(1,C1,7)
set C7 =SUM(C1:C3)
set C8 =C4&"!"
dump
set C3 10
dump
set C3 =C4
dump
set D1 =SUM(D1:D3)
set D2 1
set D3 2
get D1
set D1 =SUM(D2:D3)
get D1
set E1 =E2
set E2 =E1
set F1 =F2
set F2 =F1
set G1 =E1+F1
get G1
set E2 1
get G1
set F2 2
get G1
''')

add('cycles_static_if', '''set A1 =IF(0,A1,5)
get A1
set A2 =IF(1,5,A2)
get A2
set B1 =IF(0,B2,1)
set B2 =IF(0,B1,2)
get B1
get B2
set B2 2
get B1
get B2
set C1 =IF(1,C2,0)
set C2 =IF(1,C3,0)
set C3 =IF(1,C1,0)
set C4 =C1
set C5 =IF(0,C1,"safe")
dump
set C2 3
dump
''')

add('clear_and_reset', '''set A1 5
set A2 =A1*2
set A3 =SUM(A1:A2)
set A4 =A3&"/"&A1
dump
clear A1
dump
set A1 7
dump
clear A2
dump
clear A2
clear B7
dump
set B1 =B2
set B2 =B1
get B1
clear B2
get B1
get B2
set B2 =B1
get B1
clear B1
get B1
get B2
clear B2
dump
''')

add('dump_order', '''set ZZ9999 1
set A9999 2
set AA1 3
set Z1 4
set AB2 5
set A10 6
set B2 7
set A2 8
set B1 9
set A1 10
set BA3 11
set AZ3 12
set Z3 13
set AA3 14
set ZY9999 15
set A100 16
set A11 17
set A9 18
set ZZ1 19
set ZA1 20
dump
clear A1
clear ZZ9999
dump
''')

add('whitespace_in_formulas', '''set A1 5
set A2 = 1 + 2
set A3 =SUM( A1 , A2 )
set A4 =IF( A1 > 1 , "y" , "n" )
set A5 =( 1 + 2 ) * 3
set A6 = - A1
set A7 =A1&" "&A2
set A8 = "a" & "b"
set A9 =SUM(A1:A2 , 1 )
set A10 =  1  <>  2
set A11 = MAX ( 1 , 2 )
set A12 =1 <= 2
dump
''')

add('overwrite_dependencies', '''set A1 1
set A2 2
set A3 3
set B1 =A1+A2
get B1
set B1 =A3
get B1
set A1 100
set A2 200
get B1
set A3 300
get B1
set B1 42
set A3 5
get B1
set B1 =A1
get B1
set B1 "str"
set A1 7
get B1
set B1 =SUM(A1:A3)
get B1
set B1 =SUM(A2:A3)
set A1 1000
get B1
set A2 1000
get B1
set C1 =B1
set B1 =C1
get C1
set B1 =A1
get C1
get B1
''')

add('string_edge_cases', '''set A1 "café"
set A2 "日本語"
set A3 =A1&" "&A2
set A4 =A2>A1
set A5 "5"
set A6 =A5+1
set A7 =A5=5
set A8 =A5&5
set A9 "a=b"
set A10 =A9="a=b"
set A11 "SUM(A1:A2)"
set A12 =A11
set A13 =A12&"!"
set A14 "é"
set A15 "z"
set A16 =A14>A15
set A17 =""=""
set A18 =""<"a"
set A19 "éé"
set A20 =A19>A14
set A21 =A1<>A1&""
set A22 =COUNT(A1:A21)
set A23 =SUM(A1:A21)
set A24 ="x"<>"x "
set A25 =" "=""
set A26 "😀"
set A27 "ｚ"
set A28 =A26>A27
set A29 =A26<A27
set A30 =A26&A27
set A31 =A27>"z"
set A32 =A26>"z"
dump
''')

add('aggregate_order_float', '''set A1 0.1
set A2 0.1
set A3 0.1
set A4 0.1
set A5 0.1
set A6 0.1
set A7 0.1
set A8 0.1
set A9 0.1
set A10 0.1
set B1 =SUM(A1:A10)
set B2 =SUM(A1:A10)=1
set B3 =A1+A2+A3+A4+A5+A6+A7+A8+A9+A10
set B4 =B3=1
set B5 =10000000000000000+1-10000000000000000
set B6 =10000000000000000-10000000000000000+1
set B7 =SUM(10000000000000000,1,-10000000000000000)
set B8 =SUM(1,10000000000000000,-10000000000000000)
set B9 =AVG(A1:A10)
set B10 =0.1*3
set B11 =0.1*3=0.3
set B12 =1000000000000000000+1
set B13 =MAX(0.1*3,0.3)=0.1*3
set B14 =9007199254740993
set B15 =9007199254740992+1
set B16 =0.3-0.1
set B17 =B16=0.2
set C1 8.3
set D1 0.9
set C2 8.6
set D2 0.2
set B18 =SUM(C1:D2)=18
set B19 =SUM(C1,C2,D1,D2)=18
set B20 =SUM(C1:D2)-18
set B21 =SUM(C1,C2,D1,D2)-18
set B22 =SUM(D2:C1)-18
dump
''')


# ---------------------------------------------------------------------------
# Structured generated cases (with closed-form expected outputs)
# ---------------------------------------------------------------------------

def gen_long_formulas():
    lines = []
    for i in range(1, 301):
        lines.append('set A%d %d' % (i, i))
    lines.append('set B1 =' + '+'.join('A%d' % i for i in range(1, 301)))
    lines.append('set B2 =SUM(' + ','.join('A%d' % i for i in range(1, 201)) + ')')
    lines.append('set B3 =' + '(' * 100 + '1' + ')' * 100)
    nested = '1'
    for i in range(50):
        nested = 'IF(A%d>0,%s,0)' % (i + 1, nested)
    lines.append('set B4 =' + nested)
    lines.append('set B5 =' + '&'.join('A%d' % i for i in range(1, 31)))
    lines.append('set B6 =' + '-' * 99 + 'A1')
    lines.append('set B7 =' + '*'.join(['2'] * 40))
    lines.append('set B8 =' + '-'.join('A%d' % i for i in range(1, 101)))
    lines.append('get B1\nget B2\nget B3\nget B4\nget B5\nget B6\nget B7\nget B8')
    lines.append('set A1 1000')
    lines.append('get B1\nget B2\nget B3\nget B4\nget B5\nget B6\nget B7\nget B8')
    exp = []
    for a1 in (1, 1000):
        vals = {i: i for i in range(1, 301)}
        vals[1] = a1
        exp.append(str(sum(vals[i] for i in range(1, 301))))
        exp.append(str(sum(vals[i] for i in range(1, 201))))
        exp.append('1')
        exp.append('1')
        exp.append(''.join(str(vals[i]) for i in range(1, 31)))
        exp.append(str(-a1))
        exp.append(str(2 ** 40))
        exp.append(str(vals[1] - sum(vals[i] for i in range(2, 101))))
    return '\n'.join(lines) + '\n', '\n'.join(exp) + '\n'


text, exp = gen_long_formulas()
add('long_formulas', text)
analytic['long_formulas'] = exp


def chain_cell(i):
    """The i-th cell (1-based) of a chain that runs down column A and
    continues in column B after row 9999."""
    return 'A%d' % i if i <= 9999 else 'B%d' % (i - 9999)


def gen_chain(n, edits, rng):
    lines = ['set A1 1']
    for i in range(2, n + 1):
        lines.append('set %s =%s+1' % (chain_cell(i), chain_cell(i - 1)))
    exp = []
    for _ in range(edits):
        v = rng.randint(-1000, 1000)
        lines.append('set A1 %d' % v)
        lines.append('get %s' % chain_cell(n))
        exp.append(str(v + n - 1))
    lines.append('set %s =%s*2' % (chain_cell(n // 2), chain_cell(n // 2 - 1)))
    lines.append('get %s' % chain_cell(n))
    last = v
    exp.append(str((last + n // 2 - 2) * 2 + (n - n // 2)))
    return '\n'.join(lines) + '\n', '\n'.join(exp) + '\n'


text, exp = gen_chain(1000, 200, random.Random(1001))
add('chain_1000_edits', text)
analytic['chain_1000_edits'] = exp


def gen_string_chain(n):
    lines = ['set A1 "x"']
    for i in range(2, n + 1):
        lines.append('set A%d =A%d&"x"' % (i, i - 1))
    lines.append('set B1 =A%d="' % n + 'x' * n + '"')
    lines.append('get B1')
    lines.append('set A1 "y"')
    lines.append('get B1')
    lines.append('get A%d' % n)
    lines.append('set A1 1')
    lines.append('get A%d' % 3)
    lines.append('get A%d' % n)
    exp = ['1', '0', 'y' + 'x' * (n - 1), '1xx', '1' + 'x' * (n - 1)]
    return '\n'.join(lines) + '\n', '\n'.join(exp) + '\n'


text, exp = gen_string_chain(1000)
add('string_chain_1000', text)
analytic['string_chain_1000'] = exp


def gen_grid(n):
    """n x n grid: first row and column constants, interior (left+up)/2+1."""
    lines = []
    for c in range(1, n + 1):
        lines.append('set %s 1' % cn(1, c))
    for r in range(2, n + 1):
        lines.append('set %s 1' % cn(r, 1))
    for r in range(2, n + 1):
        for c in range(2, n + 1):
            lines.append('set %s =(%s+%s)/2+1' % (cn(r, c), cn(r, c - 1), cn(r - 1, c)))

    def compute(a1):
        g = [[1.0] * (n + 1) for _ in range(n + 1)]
        g[1][1] = a1
        for r in range(2, n + 1):
            for c in range(2, n + 1):
                g[r][c] = (g[r][c - 1] + g[r - 1][c]) / 2 + 1
        return g

    exp = []
    for a1 in (1.0, 100.0, -50.0, 0.5):
        if a1 != 1.0:
            lines.append('set A1 %s' % ref.format_number(a1))
        g = compute(a1)
        for (r, c) in ((n, n), (2, 2), (n // 2, n // 2), (n, 2), (2, n)):
            lines.append('get %s' % cn(r, c))
            exp.append(ref.format_number(g[r][c]))
    lines.append('set %s =%s&"|"&%s' % (cn(n + 1, 1), cn(n, n), cn(2, 2)))
    lines.append('get %s' % cn(n + 1, 1))
    exp.append(ref.format_number(g[n][n]) + '|' + ref.format_number(g[2][2]))
    return '\n'.join(lines) + '\n', '\n'.join(exp) + '\n'


text, exp = gen_grid(100)
add('grid_100x100', text)
analytic['grid_100x100'] = exp

text, exp = gen_chain(10000, 100, random.Random(10000))
add('chain_10k_edits', text)
analytic['chain_10k_edits'] = exp


def gen_chain_cycle(n):
    head, mid, last = 'A1', chain_cell(n // 2), chain_cell(n)
    lines = ['set A1 =%s' % last]
    for i in range(2, n + 1):
        lines.append('set %s =%s+1' % (chain_cell(i), chain_cell(i - 1)))
    lines.append('set C1 =%s' % mid)
    lines.append('set C2 =IF(0,%s,"masked")' % last)
    lines.append('set C3 =SUM(A1:A9999,B1:B%d)' % (n - 9999))
    probe = 'get A1\nget %s\nget %s\nget C1\nget C2\nget C3' % (mid, last)
    lines.append(probe)
    exp = ['#CYCLE!', '#CYCLE!', '#CYCLE!', '#CYCLE!', 'masked', '#CYCLE!']
    lines.append('set A1 10')
    lines.append(probe)
    exp += ['10', str(10 + n // 2 - 1), str(10 + n - 1), str(10 + n // 2 - 1), 'masked',
            str(sum(10 + i for i in range(n)))]
    lines.append('set %s =%s+%s' % (mid, chain_cell(n // 2 - 1), last))
    lines.append(probe)
    exp += ['10', '#CYCLE!', '#CYCLE!', '#CYCLE!', 'masked', '#CYCLE!']
    lines.append('set %s =%s+1' % (mid, chain_cell(n // 2 - 1)))
    lines.append('set A1 =%s' % last)
    lines.append(probe)
    exp += ['#CYCLE!'] * 4 + ['masked', '#CYCLE!']
    lines.append('clear A1')
    lines.append('get A1\nget A2\n' + probe.split('\n', 1)[1])
    exp += ['', '1', str(n // 2 - 1), str(n - 1), str(n // 2 - 1), 'masked',
            str(sum(range(1, n)))]
    return '\n'.join(lines) + '\n', '\n'.join(exp) + '\n'


text, exp = gen_chain_cycle(10000)
add('chain_10k_cycle', text)
analytic['chain_10k_cycle'] = exp


def gen_fanin(n, edits, rng):
    vals = {}
    lines = []
    for i in range(1, n + 1):
        v = rng.randint(-500, 500)
        vals[i] = v
        lines.append('set A%d %d' % (i, v))
    lines.append('set B1 =SUM(A1:A%d)' % n)
    lines.append('set B2 =AVG(A1:A%d)' % n)
    lines.append('set B3 =MAX(A1:A%d)' % n)
    lines.append('set B4 =MIN(A1:A%d)' % n)
    lines.append('set B5 =COUNT(A1:A%d)' % n)
    lines.append('set B6 =B1&"/"&B5')
    exp = []

    def snapshot():
        nums = [vals[i] for i in range(1, n + 1) if isinstance(vals[i], int)]
        s = 0.0
        for v in nums:
            s += v
        lines.append('get B1\nget B2\nget B3\nget B4\nget B5\nget B6')
        exp.extend([ref.format_number(s), ref.format_number(s / len(nums)),
                    str(max(nums)), str(min(nums)), str(len(nums)),
                    ref.format_number(s) + '/' + str(len(nums))])

    snapshot()
    for _ in range(edits):
        i = rng.randint(1, n)
        if rng.random() < 0.1:
            vals[i] = 'text'
            lines.append('set A%d "text"' % i)
        else:
            v = rng.randint(-500, 500)
            vals[i] = v
            lines.append('set A%d %d' % (i, v))
        snapshot()
    lines.append('set A%d =B1' % (n // 3))
    lines.append('get B1\nget B6')
    exp.extend(['#CYCLE!', '#CYCLE!'])
    lines.append('clear A%d' % (n // 3))
    del vals[n // 3]
    vals[n // 3] = 'gone'
    snapshot()
    return '\n'.join(lines) + '\n', '\n'.join(exp) + '\n'


text, exp = gen_fanin(9999, 100, random.Random(777))
add('fanin_10k', text)
analytic['fanin_10k'] = exp


def gen_wide_sheet(rows, edits, rng):
    """Five columns of 9999 rows; thousands of point edits with gets."""
    a = {}
    lines = []
    for r in range(1, rows + 1):
        a[r] = rng.randint(0, 1000)
        lines.append('set A%d %d' % (r, a[r]))
    for r in range(1, rows + 1):
        lines.append('set B%d =A%d*2' % (r, r))
    for r in range(1, rows + 1):
        lines.append('set C%d =B%d+A%d' % (r, r, r))
    for r in range(1, rows + 1):
        lines.append('set D%d =IF(C%d>1500,"hi",C%d)' % (r, r, r))
    for r in range(1, rows + 1):
        lines.append('set E%d =C%d&"!"&D%d' % (r, r, r))

    def row_expect(r):
        c = a[r] * 3
        d = 'hi' if c > 1500 else str(c)
        return [str(c), d, '%d!%s' % (c, d)]

    exp = []
    for _ in range(edits):
        r = rng.randint(1, rows)
        a[r] = rng.randint(0, 1000)
        lines.append('set A%d %d' % (r, a[r]))
        lines.append('get C%d\nget D%d\nget E%d' % (r, r, r))
        exp.extend(row_expect(r))
    lines.append('get E%d' % rows)
    exp.extend(row_expect(rows)[2:])
    return '\n'.join(lines) + '\n', '\n'.join(exp) + '\n'


text, exp = gen_wide_sheet(9999, 5000, random.Random(4242))
add('wide_sheet_point_edits', text)
analytic['wide_sheet_point_edits'] = exp


# ---------------------------------------------------------------------------
# Random workbooks (checked against the from-scratch oracle)
# ---------------------------------------------------------------------------

STRINGS = ['', 'a', 'abc', 'hello world', '10', 'B', 'x y', 'zz']


class Gen:
    def __init__(self, rng, cols, rows, string_weight=0.15, ref_weight=0.45, func_weight=0.2):
        self.rng = rng
        self.cols = cols
        self.rows = rows
        self.sw = string_weight
        self.rw = ref_weight
        self.fw = func_weight

    def cell(self):
        return cn(self.rng.randint(1, self.rows), self.rng.randint(1, self.cols))

    def number(self):
        r = self.rng.random()
        if r < 0.6:
            return str(self.rng.randint(0, 20))
        if r < 0.9:
            return '%d.%d' % (self.rng.randint(0, 99), self.rng.randint(0, 99))
        return str(self.rng.choice([0, 1, 100, 1000, 12345.678, 0.001, 3.14159]))

    def leaf(self):
        r = self.rng.random()
        if r < self.rw:
            return self.cell()
        if r < self.rw + self.sw:
            return '"%s"' % self.rng.choice(STRINGS)
        return self.number()

    def rng_arg(self):
        a = self.cell()
        b = self.cell()
        return a + ':' + b

    def expr(self, depth):
        rng = self.rng
        if depth <= 0 or rng.random() < 0.3:
            return self.leaf()
        r = rng.random()
        if r < 0.35:
            op = rng.choice(['+', '-', '*', '/', '+', '*'])
            return '%s%s%s' % (self.expr(depth - 1), op, self.expr(depth - 1))
        if r < 0.45:
            return '-' + self.expr(depth - 1)
        if r < 0.55:
            return '(' + self.expr(depth - 1) + ')'
        if r < 0.63:
            op = rng.choice(['=', '<>', '<', '>', '<=', '>='])
            return '%s%s%s' % (self.expr(depth - 1), op, self.expr(depth - 1))
        if r < 0.7:
            return '%s&%s' % (self.expr(depth - 1), self.expr(depth - 1))
        if r < 0.7 + self.fw:
            name = rng.choice(['SUM', 'MIN', 'MAX', 'AVG', 'COUNT'])
            args = []
            for _ in range(rng.randint(1, 3)):
                if rng.random() < 0.5:
                    args.append(self.rng_arg())
                else:
                    args.append(self.expr(depth - 1))
            return '%s(%s)' % (name, ','.join(args))
        return 'IF(%s,%s,%s)' % (self.expr(depth - 1), self.expr(depth - 1), self.expr(depth - 1))

    def content(self):
        r = self.rng.random()
        if r < 0.55:
            return '=' + self.expr(self.rng.randint(1, 4))
        if r < 0.8:
            return self.number()
        return '"%s"' % self.rng.choice(STRINGS)

    def commands(self, n, dump_p=0.04, get_p=0.25, clear_p=0.06):
        out = []
        for _ in range(n):
            r = self.rng.random()
            if r < dump_p:
                out.append('dump')
            elif r < dump_p + get_p:
                out.append('get ' + self.cell())
            elif r < dump_p + get_p + clear_p:
                out.append('clear ' + self.cell())
            else:
                out.append('set %s %s' % (self.cell(), self.content()))
        out.append('dump')
        return '\n'.join(out) + '\n'


add('random_small_1', Gen(random.Random(1), 3, 3).commands(60), oracle=True)
add('random_small_2', Gen(random.Random(2), 4, 4, string_weight=0.3).commands(80), oracle=True)
add('random_medium_1', Gen(random.Random(3), 5, 6).commands(500), oracle=True)
add('random_medium_2', Gen(random.Random(4), 6, 8, func_weight=0.3).commands(600), oracle=True)
add('random_cycles', Gen(random.Random(5), 4, 5, ref_weight=0.7, string_weight=0.05).commands(800, clear_p=0.1), oracle=True)
add('random_strings', Gen(random.Random(6), 5, 5, string_weight=0.4, ref_weight=0.4).commands(600), oracle=True)
add('random_large_1', Gen(random.Random(7), 8, 12).commands(5000, dump_p=0.01), oracle=True)
add('random_large_2', Gen(random.Random(8), 12, 30, ref_weight=0.55).commands(8000, dump_p=0.005), oracle=True)


# ---------------------------------------------------------------------------
# Oracle: rebuild the whole sheet from scratch after every command
# ---------------------------------------------------------------------------

UNSET = object()


class LazySheet(ref.Sheet):
    """Evaluates cells on demand with memoisation; cyclic cells are found by
    a plain reachability search before any evaluation."""

    def __init__(self, contents):
        super().__init__()
        self.cyclic = set()
        for key, content in contents.items():
            if content.startswith('='):
                try:
                    ast = ref.Parser(ref.tokenize(content[1:])).formula()
                    deps = set()
                    ref.collect_deps(ast, deps)
                except ref.BadRef:
                    ast, deps = ('referr',), set()
                self.cells[key] = ref.Cell(ast, UNSET, deps)
            elif content.startswith('"'):
                self.cells[key] = ref.Cell(None, content[1:-1], ())
            else:
                self.cells[key] = ref.Cell(None, float(content), ())
        for key, cell in self.cells.items():
            if cell.ast is None:
                continue
            seen = set()
            stack = list(cell.deps)
            while stack:
                k = stack.pop()
                if k == key:
                    self.cyclic.add(key)
                    break
                if k in seen:
                    continue
                seen.add(k)
                c = self.cells.get(k)
                if c is not None and c.ast is not None:
                    stack.extend(c.deps)

    def value_of(self, key):
        c = self.cells.get(key)
        if c is None:
            return None
        if c.value is UNSET:
            c.value = ref.CYCLE if key in self.cyclic else self.evaluate(c)
        return c.value


def oracle_run(text):
    contents = {}
    out = []
    for line in text.split('\n'):
        if not line:
            continue
        if line.startswith('set '):
            sp = line.index(' ', 4)
            contents[ref.parse_cell_name(line[4:sp])] = line[sp + 1:]
        elif line.startswith('clear '):
            contents.pop(ref.parse_cell_name(line[6:]), None)
        elif line.startswith('get '):
            out.append(ref.display(LazySheet(contents).value_of(ref.parse_cell_name(line[4:]))))
        else:
            sheet = LazySheet(contents)
            for key in sorted(contents):
                out.append(ref.cell_name(key) + ' ' + ref.display(sheet.value_of(key)))
    return '\n'.join(out) + ('\n' if out else '')


# ---------------------------------------------------------------------------
# Number-format checks
# ---------------------------------------------------------------------------

def is_rounding_tie(v):
    """True if the exact decimal value of v has exactly 11 significant digits
    ending in 5, i.e. rounding to 10 digits is an exact tie."""
    if v == 0 or (v == int(v) and abs(v) < 1e15):
        return False
    digits = Decimal(v).as_tuple().digits
    while digits and digits[-1] == 0:
        digits = digits[:-1]
    return len(digits) == 11 and digits[-1] == 5


def check_formatter(rng, n):
    for _ in range(n):
        kind = rng.random()
        if kind < 0.4:
            v = rng.uniform(-1e6, 1e6)
        elif kind < 0.7:
            v = rng.uniform(-1, 1) * 10.0 ** rng.randint(-12, 25)
        elif kind < 0.85:
            v = rng.randint(-10 ** 18, 10 ** 18) / 2 ** rng.randint(0, 20)
        else:
            v = float(rng.randint(1, 10 ** 12)) / 10 ** rng.randint(1, 6)
        if v == 0:
            continue
        expect = str(int(v)) if v == int(v) and abs(v) < 1e15 else '%.10g' % v
        got = ref.format_number(v)
        if got != expect:
            raise SystemExit('formatter mismatch for %r: %s vs %s' % (v, got, expect))
    for v, expect in [(1e15, '1e+15'), (1e14, '100000000000000'), (1234567890.5, '1234567890'),
                      (9999999999.7, '1e+10'), (1e-5, '1e-05'), (0.0001, '0.0001'),
                      (-0.0, '0'), (1 / 3, '0.3333333333'), (2 / 3, '0.6666666667'),
                      (1.5e15, '1.5e+15'), (1234567890123456.0, '1.23456789e+15')]:
        got = ref.format_number(v)
        if got != expect:
            raise SystemExit('formatter mismatch for %r: %s vs %s' % (v, got, expect))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    check_formatter(random.Random(99), 200000)

    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        os.remove(os.path.join(TESTS, f))

    seen_ties = []
    real_format = ref.format_number

    def recording_format(v):
        if is_rounding_tie(v):
            seen_ties.append(v)
        return real_format(v)

    for i, (name, text) in enumerate(cases, 1):
        base = '%03d_%s' % (i, name)
        with open(os.path.join(TESTS, base + '.in'), 'w', encoding='utf-8') as f:
            f.write(text)
        proc = subprocess.run([sys.executable, REF], input=text.encode('utf-8'),
                              capture_output=True, timeout=600)
        if proc.returncode != 0:
            raise SystemExit('reference failed on %s: %s' % (base, proc.stderr.decode()))
        out = proc.stdout.decode('utf-8')
        with open(os.path.join(TESTS, base + '.out'), 'w', encoding='utf-8') as f:
            f.write(out)

        # In-process replay to record every displayed number for the tie check.
        seen_ties.clear()
        ref.format_number = recording_format
        old_in, old_out = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO(text), io.StringIO()
        try:
            ref.main()
            inproc = sys.stdout.getvalue()
        finally:
            sys.stdin, sys.stdout = old_in, old_out
            ref.format_number = real_format
        if inproc != out:
            raise SystemExit('in-process output differs from subprocess for ' + base)
        if name != 'number_format' and seen_ties:
            raise SystemExit('rounding tie in %s: %r' % (base, seen_ties[:5]))

        if name in oracle_names:
            expect = oracle_run(text)
            if expect != out:
                raise SystemExit('oracle disagrees with reference on ' + base)
        if name in analytic:
            if analytic[name] != out:
                raise SystemExit('analytic expectation disagrees with reference on ' + base)
        print('wrote', base, '(%d lines in, %d lines out)' % (text.count('\n'), out.count('\n')))


if __name__ == '__main__':
    main()
