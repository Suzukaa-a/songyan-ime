#!/usr/bin/env python3
"""Keep the root documents from containing dead local links."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

ROOT_DOCUMENTS = ("README.md", "README.zh-CN.md", "ARCHITECTURE.md", "DEBUG.md", "CONTRIBUTING.md")


class DocumentationLinkTests(unittest.TestCase):
    def test_local_markdown_links_resolve(self):
        files = [ROOT / name for name in ROOT_DOCUMENTS]
        broken = []
        for document in files:
            if not document.is_file():
                continue
            source = document.read_text(encoding="utf-8")
            for raw_target in re.findall(r"(?<!!)\[[^]]*\]\(([^)]+)\)", source):
                target = raw_target.strip().split()[0].strip("<>")
                if target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                path = target.split("#", 1)[0]
                if path and not (document.parent / path).resolve().exists():
                    broken.append(f"{document.relative_to(ROOT)} -> {target}")
        self.assertEqual(broken, [])


if __name__ == "__main__":
    unittest.main()
