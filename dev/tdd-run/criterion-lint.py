#!/usr/bin/env python3
"""Criterion<->test bijection lint for sampleTidy (project-local).

WHY NOT THE SKILL'S criterion-lint.py: this project's criterion IDs are dotted
(`R-11.5`, `R-11.5a`). The skill's lint canonicalises a reference by stripping
non-alphanumerics from the *containing token*, and its token regex
(`[A-Za-z0-9_-]+`) splits at the dot — so `R-11.5` in a test name is seen as the
token `R-11`, canonicalises to ('r','11'), and never matches the declared
('r','115'). Every dotted criterion therefore reports UNCOVERED. Filed against
the skill in SUGGESTED-IMPROVEMENTS.md.

DECLARATION SITE (authoritative): a `## R-<n>.<m>[a]` or `### R-<n>.<m>[a]`
heading in dev/plans/PLAN-*.md. COVERAGE-MAP.md and CONTRACT.md *mention* IDs but
do not declare them, so they are not scanned — mentions there caused ~90 phantom
UNCOVERED rows.

REFERENCE SITE: any `R-<n>.<m>[a]` in tests/testthat/*.R (by convention a test is
named "R-x.y: <criterion>").

  UNCOVERED  a declared criterion no test references   -> coverage gap
  UNKNOWN    an ID in tests declared by no plan        -> typo / phantom binding
  DEFERRED   declared, uncovered, and SAID SO in the plan -> informational
  DOC-ONLY   a pointer stub with no behaviour to test     -> informational

EXEMPTION MARKERS (round-2 audit, reconcile D3). A criterion that is uncovered
*on purpose* must say so where it is declared, not in the caller's `--skip`
argument. Put a line in the criterion's own section body:

    **DEFERRED:** blocked on F.13; the test lands as an xfail (see R-15.33).
    **DOC-ONLY:** moved to PLAN-13 R-13.1 step 5 (A68); no behaviour here.

A marker suppresses UNCOVERED and prints an informational row carrying its
reason. `--skip` is retained for one-off invocations, but a deferral that
outlives the session belongs in the plan: R-15.33 was indistinguishable from an
oversight for two audit rounds precisely because its blocker lived nowhere the
lint could read.

Exit 0 = bijection holds, 1 = findings.

  python3 dev/tdd-run/criterion-lint.py [--root .] [--skip R-12.12,...]
"""
import argparse
import re
import sys
from pathlib import Path

ID = r"R-[0-9]+\.[0-9]+[a-z]?"
DECL_RE = re.compile(rf"^#{{2,3}}\s+({ID})(?![0-9A-Za-z.])", re.MULTILINE)
REF_RE = re.compile(rf"(?<![0-9A-Za-z.]){ID}(?![0-9A-Za-z.])")
# An exemption marker anywhere in the criterion's own section body. Bold
# markers are the plans' house style, so `**DEFERRED:**` must match as readily
# as a bare `DEFERRED:`.
# `**DEFERRED:**` puts the colon INSIDE the bold span, so the closing asterisks
# trail the colon rather than precede it - both sides must be optional or the
# reason capture starts with a stray `**`.
EXEMPT_RE = re.compile(
    r"^[>*_\s]*(DEFERRED|DOC-ONLY)\*{0,2}:\*{0,2}\s*(.+?)\s*$", re.MULTILINE)
NEXT_DECL_RE = re.compile(r"^#{1,3}\s", re.MULTILINE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--skip", default="",
                    help="comma-separated criterion IDs exempt from UNCOVERED "
                         "(doc-only or deliberately deferred requirements)")
    args = ap.parse_args()
    root = Path(args.root).resolve()
    skip = {s.strip() for s in args.skip.split(",") if s.strip()}

    declared = {}
    exempt = {}
    for plan in sorted((root / "dev" / "plans").glob("PLAN-*.md")):
        text = plan.read_text(encoding="utf-8")
        for m in DECL_RE.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            cid = m.group(1)
            if cid in declared:
                continue
            declared[cid] = f"{plan.relative_to(root)}:{line}"
            # The section body runs to the next heading of any level, so a
            # marker cannot leak from one criterion into the next.
            nxt = NEXT_DECL_RE.search(text, m.end())
            body = text[m.end():nxt.start() if nxt else len(text)]
            em = EXEMPT_RE.search(body)
            if em:
                exempt[cid] = (em.group(1), em.group(2))

    referenced = {}
    for test in sorted((root / "tests" / "testthat").glob("*.R")):
        text = test.read_text(encoding="utf-8", errors="replace")
        for m in REF_RE.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            referenced.setdefault(m.group(0), []).append(
                f"{test.relative_to(root)}:{line}")

    findings = 0
    for cid, where in sorted(declared.items()):
        if cid in referenced or cid in skip:
            continue
        if cid in exempt:
            kind, reason = exempt[cid]
            print(f"{kind:9s} {cid} (declared {where}) - {reason}")
            continue
        findings += 1
        print(f"UNCOVERED {cid} (declared {where}) - no test references it")
    for cid, hits in sorted(referenced.items()):
        if cid in declared:
            continue
        findings += 1
        extra = f" (+{len(hits) - 1} more)" if len(hits) > 1 else ""
        print(f"UNKNOWN   {cid} at {hits[0]}{extra} - declared by no plan")

    covered = sum(1 for c in declared if c in referenced)
    skipped = skip & set(declared)
    # A marker only earns its exemption while the criterion is actually
    # uncovered; once a test references it, it counts as covered like any
    # other, so a stale marker cannot inflate the exempt tally.
    exempted = {c for c in exempt if c not in referenced and c not in skipped}
    n_def = sum(1 for c in exempted if exempt[c][0] == "DEFERRED")
    print(f"summary: {len(declared)} declared, {covered} covered, "
          f"{len(declared) - covered - len(skipped) - len(exempted)} uncovered, "
          f"{n_def} deferred, {len(exempted) - n_def} doc-only, "
          f"{len(skipped)} skipped; "
          f"{len(set(referenced) - set(declared))} unknown")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
