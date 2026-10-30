#!/bin/bash
# the capture filter of engine/nfq/macrecv.c as one string, for tests/engine_filter.c
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 -I -c '
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"static const char \*filter =\n((?:\t\".*\"\n?)+);", s)
print("".join(re.findall(r"\"(.*?)\"", m.group(1))))' "$ROOT/engine/nfq/macrecv.c"
