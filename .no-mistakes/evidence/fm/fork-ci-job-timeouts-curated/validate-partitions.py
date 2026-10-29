import collections
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path("~/.no-mistakes/worktrees/049a88734b0e/01M6347V951V902GDY424YNJQP")
EVIDENCE = Path(__file__).parent
calls = []
env = dict(os.environ, CI="false", GITHUB_ACTIONS="false")

def call(args, rc=0, ci=False):
    proc = subprocess.run(["bin/fm-lint.sh", *args], cwd=ROOT,
        env=dict(env, CI="true" if ci else "false"), text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    calls.append(dict(args=args, ci=ci, exit=proc.returncode,
                      stdout=proc.stdout, stderr=proc.stderr))
    assert proc.returncode == rc, calls[-1]
    return proc.stdout.splitlines()

try:
    # Independent inventory oracle: direct shell-file children of the three
    # documented canonical directories, without using the partition algorithm.
    expected = sorted(str(p.relative_to(ROOT)) for folder in
                      ("bin", "bin/backends", "tests")
                      for p in (ROOT / folder).glob("*.sh") if p.is_file())
    assert sorted(call(["--list-files"], ci=True)) == expected
    summary = []
    for total in (4, 2):
        union = []
        for index in range(1, total + 1):
            part = f"{index}of{total}"
            rows = call(["--partition", part, "--list-files"])
            assert rows, f"empty partition {part}"
            assert rows == call([f"--partition={part}", "--list-files"])
            assert rows == call(["--partition", part, "--list-files"], ci=True)
            assert len(rows) == len(set(rows)), f"duplicates in {part}"
            assert set(rows) <= set(expected), f"unexpected roots in {part}"
            union.extend(rows)
            summary.append(dict(partition=part, roots=len(rows),
                bytes=sum((ROOT / p).stat().st_size for p in rows)))
            # These must refuse before analysis; no lint is run by this driver.
            for switch in (["--partition", part], [f"--partition={part}"]):
                for extra in (["--fast"], ["bin/fm-lint.sh"]):
                    call([*switch, *extra], rc=2)
        assert collections.Counter(union) == collections.Counter(expected), total
    print(f"Canonical CLI inventory: {len(expected)} shell roots.")
    for row in summary:
        print(f"{row['partition']}: {row['roots']} roots, {row['bytes']} bytes")
    print("Both partition layouts are complete and disjoint; both argument forms and local/CI selection agree.")
    print("All valid partitions reject --fast and explicit subsets with exit 2.")
    invalid = ("", "0of2", "3of2", "1of1", "1of3", "1of5", "1of6",
               "1of7", "1of8", "1of9", "0of4", "5of4", "1of", "2of2x", "abc")
    for value in invalid:
        call(["--partition", value, "--list-files"], rc=2)
        call([f"--partition={value}", "--list-files"], rc=2)
    call(["--partition"], rc=2)
    print("Missing, empty, out-of-range and unsupported partitions are rejected with exit 2.")
    print("No linters, formatters or static analysis tools were executed. File-byte totals are not runtime evidence.")
finally:
    (EVIDENCE / "partition-cli-calls.json").write_text(json.dumps(calls, indent=2) + "\n")
