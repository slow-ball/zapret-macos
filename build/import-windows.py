#!/usr/bin/env python3
"""Переносит стратегии из Windows-версии Flowseal (zapret-discord-youtube) в src/nfqws.

Запуск: build/import-windows.py <распакованный релиз Windows-версии> [папка src/nfqws] [--lists src]

Из каждого general*.bat берётся командная строка winws.exe, пути заменяются на
@LISTS@/, @BASE@/bin/ и @IPSET@. Профили игрового фильтра (%GameFilter...%) уходят
в отдельные <стратегия>.game-tcp.conf.in и .game-udp.conf.in с @GAME_TCP@, @GAME_UDP@
и @GAMEIPSET@: они подключаются, только когда игровой фильтр включён.
Файлы фейков не копируются: их делает build/fakes.swift по именам, на которые ссылаются
стратегии (запускается после импорта). IP-список для игр (.service/ipset-service.txt) — в <папка>/ipset-game.txt,
номер версии — в <папка>/windows-version.
С --lists src новые домены из списков Windows-версии добавляются в src/list-general.txt
и src/list-exclude.txt, а src/list-google.txt и src/ipset-exclude.txt заменяются (первая
строка-комментарий остаётся).
Домены, SHA256 которых есть в build/skip-domains.sha256, в проект не попадают: из списков
они выбрасываются, а файлы фейков с таким доменом в имени получают нейтральное имя.
"""

import hashlib
import pathlib
import re
import shlex
import sys


def convert(bat_text):
    text = bat_text.replace("\r", "")
    # continuation lines end with ^
    text = re.sub(r"\^\n", " ", text)
    line = next(l for l in text.split("\n") if "winws.exe" in l)
    # batch escapes: ^x is x, %% is %
    line = re.sub(r"\^(.)", r"\1", line).replace("%%", "%")
    args = shlex.split(line.split('winws.exe"', 1)[1])
    profiles, cur = [], []
    for a in args + ["--new"]:
        if a == "--new":
            profiles.append(cur)
            cur = []
        else:
            cur.append(a)
    out = {"main": [], "game-tcp": [], "game-udp": []}
    for p in profiles:
        # --wf-* are WinDivert port filters (on macOS pf does that), they also mention the game filter
        p = [a for a in p if not a.startswith(("--wf-tcp=", "--wf-udp="))]
        if not p:
            continue
        game = any("%GameFilter" in a for a in p)
        kind = "main"
        if game:
            kind = "game-udp" if any(a.startswith("--filter-udp=") for a in p) else "game-tcp"
        if out[kind]:
            out[kind].append("--new")
        for a in p:
            a = a.replace("%GameFilterTCP%", "@GAME_TCP@").replace("%GameFilterUDP%", "@GAME_UDP@")
            a = a.replace("%LISTS%ipset-all.txt", "@GAMEIPSET@" if game else "@IPSET@")
            a = a.replace("%LISTS%", "@LISTS@/").replace("%BIN%", "@BASE@/bin/")
            if "=" in a and ("@" in a.split("=", 1)[1]):
                k, v = a.split("=", 1)
                a = '%s="%s"' % (k, v)
            out[kind].append(a)
    return out


SKIP = {l.strip() for l in (pathlib.Path(__file__).parent / "skip-domains.sha256").read_text().split("\n")
        if l.strip() and not l.startswith("#")}


def skipped(domain):
    return hashlib.sha256(domain.lstrip("^").encode()).hexdigest() in SKIP


def bin_name(name):
    # tls_clienthello_www_example_com.bin → www.example.com, and the parent domains
    m = re.match(r"(tls_clienthello|quic_initial)_(.+)\.bin$", name)
    if not m:
        return name
    parts = m.group(2).split("_")
    if any(skipped(".".join(parts[i:])) for i in range(len(parts) - 1)):
        return "%s_%s.bin" % (m.group(1), hashlib.sha256(name.encode()).hexdigest()[:8])
    return name


def entries(path):
    return [l.strip() for l in path.read_text(errors="replace").replace("\r", "").split("\n")
            if l.strip() and not l.startswith("#") and not skipped(l.strip())]


def merge_lists(win, src, version):
    for name in ("list-general.txt", "list-exclude.txt"):
        ours = src / name
        new = [e for e in entries(win / "lists" / name) if e not in set(entries(ours))]
        if new:
            with ours.open("a") as f:
                f.write("# Windows-версия %s\n%s\n" % (version, "\n".join(new)))
    for name in ("list-google.txt", "ipset-exclude.txt"):
        ours = src / name
        head = ours.read_text().split("\n", 1)[0]
        ours.write_text(head + "\n" + "\n".join(entries(win / "lists" / name)) + "\n")


def main():
    args = sys.argv[1:]
    lists = None
    if "--lists" in args:
        i = args.index("--lists")
        lists = pathlib.Path(args[i + 1])
        del args[i:i + 2]
    win = pathlib.Path(args[0])
    dst = pathlib.Path(args[1] if len(args) > 1 else "src/nfqws")
    version = (win / ".service" / "version.txt").read_text().strip()
    (dst / "strategies").mkdir(parents=True, exist_ok=True)
    for old in (dst / "strategies").glob("*.conf.in"):
        old.unlink()
    service = win / ".service" / "ipset-service.txt"
    if service.exists():
        (dst / "ipset-game.txt").write_text(service.read_text().replace("\r", ""))

    def order(path):
        # general, general (ALT), (ALT2)…, then the named ones, as in the Windows menu
        m = re.search(r"\(ALT(\d*)\)", path.name)
        return (0 if path.name == "general.bat" else 1 if m else 2, int(m.group(1) or 1) if m else 0,
                path.stem.replace(")", ""))

    rows, bins = [], set()
    for bat in sorted(win.glob("general*.bat"), key=order):
        name = bat.stem
        file = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        parts = convert(bat.read_text(encoding="utf-8", errors="replace"))
        for kind, lines in parts.items():
            if not lines:
                continue
            suffix = "" if kind == "main" else "." + kind
            used = re.findall(r"@BASE@/bin/([^\"]+)", "\n".join(lines))
            text = "\n".join(lines) + "\n"
            for b in used:
                text = text.replace("@BASE@/bin/" + b + '"', "@BASE@/bin/" + bin_name(b) + '"')
            (dst / "strategies" / (file + suffix + ".conf.in")).write_text(text)
            bins.update(used)
        rows.append("%s\t%s" % (file, name))
    (dst / "strategies.tsv").write_text("\n".join(rows) + "\n")
    (dst / "windows-version").write_text(version + "\n")
    if lists:
        merge_lists(win, lists, version)
    print("Windows %s: стратегий %d, файлов фейков %d" % (version, len(rows), len(bins)))


if __name__ == "__main__":
    main()
