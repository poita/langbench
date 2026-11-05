import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("code_stats", os.path.join(HERE, "..", "tools", "code_stats.py"))
cs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cs)


def write(root, rel, lines):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


class Classify(unittest.TestCase):
    def test_test_files_by_language_convention(self):
        self.assertTrue(cs.is_test("go", "pkg/machine_test.go"))
        self.assertFalse(cs.is_test("go", "pkg/machine.go"))
        self.assertTrue(cs.is_test("python", "tests/test_machine.py"))
        self.assertTrue(cs.is_test("rust", "tests/cpu.rs"))
        self.assertTrue(cs.is_test("d", "tests/machine_test.d"))
        self.assertTrue(cs.is_test("cpp", "tests/test_main.cpp"))
        self.assertFalse(cs.is_test("cpp", "src/main.cpp"))


class Counts(unittest.TestCase):
    def test_lines_exclude_blank_lines_build_outputs_and_non_source(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, "src/lib.rs", ["fn a() {}", "", "fn b() {}"])
            write(d, "tests/t.rs", ["#[test]", "fn t() {}"])
            write(d, "target/release/build/x.rs", ["fn junk() {}"] * 50)
            write(d, "README.md", ["# x"] * 10)
            self.assertEqual(cs.project_lines(d, "rust"), {"code": 2, "test": 2})

    def test_rust_inline_test_modules_count_as_tests(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, "src/lib.rs", ["fn a() {}", "#[cfg(test)]", "mod tests {", "    #[test]", "    fn t() {}", "}"])
            self.assertEqual(cs.project_lines(d, "rust"), {"code": 1, "test": 5})


if __name__ == "__main__":
    unittest.main()
