import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_readme_python_examples_run():
    with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as handle:
        text = handle.read()
    blocks = re.findall(r"```python\n(.*?)```", text, re.S)
    assert blocks
    for block in blocks:
        exec(compile(block, "README.md", "exec"), {"__name__": "__readme__"})
