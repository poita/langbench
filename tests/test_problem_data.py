import glob
import json
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def reject(token):
    raise ValueError(f"non-JSON token {token}")


class JsonSchemaInputs(unittest.TestCase):
    def test_every_input_is_strict_json(self):
        """Implementations write their own JSON parser, so test inputs use only RFC 8259 JSON."""
        for path in sorted(glob.glob(os.path.join(ROOT, "problems", "jsonschema", "tests", "*.in"))):
            with self.subTest(os.path.basename(path)):
                with open(path) as f:
                    json.load(f, parse_constant=reject)


class NoPersonalPaths(unittest.TestCase):
    def test_no_tracked_file_names_a_home_directory(self):
        """Tracked files must work on any machine, so none names the home directory of whoever runs the checks
        (vendored data may contain other people's paths, such as CVS paths in mailing-list archives)."""
        import re
        import subprocess
        files = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], capture_output=True, text=True,
                               check=True).stdout.split("\0")
        home = re.compile(re.escape(os.path.expanduser("~").encode()) + rb"(/|\b)")
        offenders = []
        for rel in filter(None, files):
            path = os.path.join(ROOT, rel)
            if not os.path.isfile(path) or rel.endswith(".tar.gz"):
                continue
            with open(path, "rb") as f:
                data = f.read()
            if b"\0" in data[:4096]:
                continue
            if home.search(data):
                offenders.append(rel)
        self.assertEqual(offenders, [])


def tracked_files():
    import subprocess
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], capture_output=True, text=True, check=True).stdout
    return [rel for rel in out.split("\0") if rel and os.path.isfile(os.path.join(ROOT, rel))]


class NoExecutables(unittest.TestCase):
    # Executable headers, raw and base64-encoded as a mail attachment would carry them.
    RAW = (b"MZ", b"\x7fELF", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe")
    ENCODED = (b"TVqQAAMAAAAEAAAA", b"TVoAAAAAAAAAAAAA", b"TVpQAAIAAAAEAA", b"f0VMRgIBAQ")

    def test_no_tracked_file_is_or_embeds_an_executable(self):
        """Test data must be safe to clone: antivirus software flags executables, and hosts forbid malware."""
        offenders = []
        for rel in tracked_files():
            if not rel.startswith("problems/"):
                continue
            with open(os.path.join(ROOT, rel), "rb") as f:
                data = f.read()
            if data.startswith(self.RAW) and not data.startswith(b"MZ ") or any(e in data for e in self.ENCODED):
                offenders.append(rel)
        self.assertEqual(offenders, [])


class FulltextBooksArePublicDomain(unittest.TestCase):
    # Project Gutenberg ebooks it lists as copyrighted, such as translations by living translators.
    COPYRIGHTED = {5200}

    def test_no_vendored_book_is_copyrighted(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("make_corpus", os.path.join(ROOT, "problems/fulltext/make_corpus.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertEqual([b for b in mod.BOOKS if b[0] in self.COPYRIGHTED], [])
        listed = open(os.path.join(ROOT, "problems/fulltext/corpus/LICENSE")).read()
        for num, name, _title, _author in mod.BOOKS:
            self.assertIn("%s.txt" % name, listed)
            self.assertIn("(#%d)" % num, listed)


class SimpleIconsAreCC0(unittest.TestCase):
    # Icons that simple-icons 13.21.0 ships under their own licences rather than CC0.
    NOT_CC0 = {"apachecassandra", "apacheopenoffice", "fishshell", "godotengine", "jabber", "keycloak", "neovim",
               "pleroma"}

    def test_only_cc0_icons_are_vendored(self):
        found = [rel for rel in tracked_files() if rel.startswith("problems/svgraster/")
                 and os.path.splitext(os.path.basename(rel))[0] in self.NOT_CC0]
        self.assertEqual(found, [])


class ThirdPartyLicences(unittest.TestCase):
    """Agents get a problem's tests/ without its corpus/, so the licences of third-party data travel in tests/."""
    PROBLEMS = ["commonmark", "fulltext", "gitrepo", "jsonschema", "linalg", "mime", "sitegen", "sqlitefile",
                "svgraster", "toml", "webhooks"]

    def test_tests_dirs_carry_an_index_and_every_licence_it_names(self):
        import re
        for problem in self.PROBLEMS:
            tests = os.path.join(ROOT, "problems", problem, "tests")
            index = os.path.join(tests, "THIRD_PARTY.md")
            self.assertTrue(os.path.isfile(index), problem)
            named = set(re.findall(r"`((?:LICEN[CS]E|NOTICE)[^`/]*)`", open(index).read()))
            self.assertTrue(named, problem)
            for name in named:
                self.assertTrue(os.path.isfile(os.path.join(tests, name)), (problem, name))

    def test_linalg_matrices_are_cc_by(self):
        for rel in ["corpus/LICENSE", "tests/CORPUS_LICENSE", "bench/CORPUS_LICENSE"]:
            text = open(os.path.join(ROOT, "problems/linalg", rel)).read()
            self.assertIn("CC BY 4.0", text, rel)
            self.assertNotIn("public domain", text.lower(), rel)

    def test_top_level_notices_cover_every_problem(self):
        text = open(os.path.join(ROOT, "THIRD_PARTY_NOTICES.md")).read()
        for problem in self.PROBLEMS:
            self.assertIn("problems/%s/" % problem, text)


if __name__ == "__main__":
    unittest.main()
