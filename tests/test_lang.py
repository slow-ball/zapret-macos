"""Every Russian message of the scripts has an English translation in src/lang/en.tsv, and the
English one takes the same arguments; no translation of a message that is gone.
Run: python3 -m unittest discover -s tests"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CALL = re.compile(r'(?<![\w-])(?:ok|bad|warn|die|say|msg) "((?:[^"\\]|\\.)*)"')
CYR = re.compile("[А-Яа-яЁё]")


def messages():
    out = {}
    for f in [ROOT / "src" / "zapret.sh", *sorted((ROOT / "src" / "lib").glob("*.sh"))]:
        for n, line in enumerate(f.read_text().splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in CALL.finditer(line):
                if CYR.search(m.group(1)):
                    out.setdefault(m.group(1), f"{f.name}:{n}")
    return out


def table():
    t = {}
    for line in (ROOT / "src" / "lang" / "en.tsv").read_text().splitlines():
        if line and not line.startswith("#"):
            ru, en = line.split("\t")
            t[ru] = en
    return t


def specs(s):
    return re.findall(r"%[-0-9]*[sd]", s)


class Lang(unittest.TestCase):
    def test_every_message_translated(self):
        t = table()
        missing = [f"{where}: {m}" for m, where in messages().items() if m not in t]
        self.assertEqual(missing, [])

    def test_same_arguments(self):
        for ru, en in table().items():
            self.assertEqual(specs(ru), specs(en), ru)

    def test_no_bare_russian_echo(self):
        # an unquoted echo of Russian words passes by the translation
        for f in [ROOT / "src" / "zapret.sh", *sorted((ROOT / "src" / "lib").glob("*.sh"))]:
            for n, line in enumerate(f.read_text().splitlines(), 1):
                self.assertFalse(re.search(r"\becho [А-Яа-яЁё]", line), f"{f.name}:{n}")

    def test_no_unused_translation(self):
        # a message gone from the scripts takes its translation with it
        used = messages()
        code = "\n".join(f.read_text() for f in [ROOT / "src" / "zapret.sh", ROOT / "src" / "nfqws" / "run.sh",
                                                  *sorted((ROOT / "src" / "lib").glob("*.sh"))])
        unused = [ru for ru in table() if ru not in used and ru not in code]
        self.assertEqual(unused, [])

    def test_no_russian_in_english(self):
        for ru, en in table().items():
            self.assertFalse(CYR.search(en), en)


if __name__ == "__main__":
    unittest.main()
