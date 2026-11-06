# Common commands; see README.md for details.
.PHONY: check references test results bench bench-long

# Structure, run configuration, run provenance, canonical implementations and unit tests
check:
	python3 tools/check.py

# Every reference implementation on its public tests (slow)
references:
	python3 tools/check.py --references

test:
	python3 -m unittest discover -s tests

# Rewrite results/README.md from implementations/
results:
	python3 tools/results_report.py

# Generate every problem's benchmark inputs and expected outputs (about 30 minutes, once)
bench:
	for g in problems/*/bench/gen_bench.py; do (cd $$(dirname $$(dirname $$g)) && python3 bench/gen_bench.py) || exit 1; done

# Generate the long benchmark inputs (each at least 5 s for the fastest implementation; slow, once)
bench-long:
	for g in problems/*/bench/gen_bench.py; do (cd $$(dirname $$(dirname $$g)) && python3 bench/gen_bench.py --long) || exit 1; done
