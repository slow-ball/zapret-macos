"""Тесты переноса стратегий из Windows-версии (build/import-windows.py).
Запуск: python3 -m unittest discover -s tests"""

import hashlib
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("import_windows", ROOT / "build" / "import-windows.py")
iw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(iw)

BAT = r'''@echo off
start "zapret: %~n0" /min "%BIN%winws.exe" --wf-tcp=80,443,%GameFilterTCP% --wf-udp=443,%GameFilterUDP% ^
--filter-udp=443 --hostlist="%LISTS%list-general.txt" --dpi-desync=fake --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --dpi-desync=fake --dpi-desync-fake-tls=^! --new ^
--filter-tcp=80,443 --ipset="%LISTS%ipset-all.txt" --dpi-desync=multisplit --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_blocked_example.bin" --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --dpi-desync=syndata --new ^
--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --dpi-desync=fake --dpi-desync-cutoff=n2
'''


class Convert(unittest.TestCase):
    def setUp(self):
        self.parts = iw.convert(BAT)

    def test_main_profiles(self):
        main = self.parts["main"]
        self.assertEqual(main.count("--new"), 2)
        self.assertNotIn("--wf-tcp", " ".join(main))
        self.assertIn('--hostlist="@LISTS@/list-general.txt"', main)

    def test_batch_escapes(self):
        # ^! in batch is !
        self.assertIn("--dpi-desync-fake-tls=!", self.parts["main"])

    def test_ipset_placeholders(self):
        self.assertIn('--ipset="@IPSET@"', self.parts["main"])
        self.assertIn('--ipset="@GAMEIPSET@"', self.parts["game-tcp"])

    def test_game_profiles_apart(self):
        self.assertIn('--filter-tcp="@GAME_TCP@"', self.parts["game-tcp"])
        self.assertIn('--filter-udp="@GAME_UDP@"', self.parts["game-udp"])
        self.assertNotIn("@GAME_", " ".join(self.parts["main"]))


class Skip(unittest.TestCase):
    """Domains whose SHA256 is listed never get into the project, not even in file names"""

    def setUp(self):
        self.saved = iw.SKIP
        iw.SKIP = {hashlib.sha256(b"blocked.example").hexdigest()}

    def tearDown(self):
        iw.SKIP = self.saved

    def test_bin_renamed(self):
        name = iw.bin_name("tls_clienthello_blocked_example.bin")
        self.assertNotIn("blocked", name)
        self.assertTrue(name.startswith("tls_clienthello_") and name.endswith(".bin"))

    def test_other_bins_kept(self):
        self.assertEqual(iw.bin_name("tls_clienthello_www_google_com.bin"), "tls_clienthello_www_google_com.bin")

    def test_list_entries_dropped(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "list.txt"
            p.write_text("# comment\nok.example\nblocked.example\n^blocked.example\n")
            self.assertEqual(iw.entries(p), ["ok.example"])


class Release(unittest.TestCase):
    """A whole small Windows release: files, the names of fakes and the version"""

    def test_import(self):
        with tempfile.TemporaryDirectory() as d:
            win = pathlib.Path(d) / "win"
            (win / "bin").mkdir(parents=True)
            (win / "lists").mkdir()
            (win / ".service").mkdir()
            (win / ".service" / "version.txt").write_text("9.9.9\n")
            (win / "general (ALT2).bat").write_text(BAT)
            (win / "general.bat").write_text(BAT)
            for b in ("quic_initial_www_google_com.bin", "tls_clienthello_blocked_example.bin"):
                (win / "bin" / b).write_bytes(b"x")
            dst = pathlib.Path(d) / "nfqws"
            saved, iw.SKIP = iw.SKIP, set()
            try:
                iw.sys.argv = ["import-windows.py", str(win), str(dst)]
                iw.main()
            finally:
                iw.SKIP = saved
            self.assertEqual((dst / "windows-version").read_text().strip(), "9.9.9")
            rows = (dst / "strategies.tsv").read_text().splitlines()
            self.assertEqual(rows, ["general\tgeneral", "general-alt2\tgeneral (ALT2)"])
            self.assertTrue((dst / "strategies" / "general.game-tcp.conf.in").exists())
            # the fakes are build/fakes.swift's: none copied, the names in the strategies, a blocked one renamed
            self.assertFalse((dst / "bin").exists())
            text = (dst / "strategies" / "general.conf.in").read_text()
            self.assertIn("@BASE@/bin/quic_initial_www_google_com.bin", text)


if __name__ == "__main__":
    unittest.main()
