#!/usr/bin/env python3
"""Release-notes gate and release-page body (spec section 16.37).

    release_notes.py check <version> [CHANGELOG.md]
    release_notes.py body  <version> <out_file> [CHANGELOG.md]

`check` fails (exit 1) a FULL release whose CHANGELOG.md has no
`## <version> - <YYYY-MM-DD>` entry, whose entry has no summary or no items,
or whose `## Unreleased` entry still has content. A PRE-release (a version
with `-`) never fails: it only warns when Unreleased is empty.

`body` writes the GitHub release description: the release's entry (full
release) or the Unreleased entry (pre-release).

Standard library only. The grammar is the one lua/loomworks/release_notes.lua
implements (the runtime and the test suite); this script reads only headings,
the summary and the bullets, which is all the gate needs.
"""
import os
import re
import sys

HEADING = re.compile(r"^## (?:(Unreleased)|(\S+) - (\d{4}-\d{2}-\d{2}))\s*$")
HOWTO = """\
How to fix: in CHANGELOG.md, rename the `## Unreleased` heading to

    ## {version} - {date}

add a one- or two-sentence summary paragraph right under it, put an empty
`## Unreleased` heading back above it, commit, and move the tag
(git tag -f v{version} && git push -f <remote> v{version}).
See the comment at the top of CHANGELOG.md."""


def strip_comments(lines):
    out, in_c = [], False
    for line in lines:
        if in_c:
            if "-->" in line:
                in_c = False
            continue
        if line.lstrip().startswith("<!--"):
            in_c = "-->" not in line
            continue
        out.append(line)
    return out


def entries(text):
    """[(key, heading_line, body_lines)] where key is 'Unreleased' or a version."""
    res, cur = [], None
    for line in strip_comments(text.replace("\r\n", "\n").split("\n")):
        m = HEADING.match(line)
        if m:
            cur = (m.group(1) or m.group(2), line, [])
            res.append(cur)
        elif line.startswith("## "):
            cur = ("?", line, [])
            res.append(cur)
        elif cur is not None:
            cur[2].append(line)
    return res


def summary_and_items(body):
    summary, items = [], 0
    in_summary = True
    for line in body:
        if line.startswith("### "):
            in_summary = False
        elif line.startswith("- "):
            items += 1
            in_summary = False
        elif line.strip() == "":
            if summary:
                in_summary = False
        elif in_summary:
            summary.append(line.strip())
    return " ".join(summary), items


def find(ents, key):
    for e in ents:
        if e[0] == key:
            return e
    return None


def is_pre(v):
    return "-" in v


def base(v):
    return v.split("-", 1)[0]


def body_text(e):
    lines = list(e[2])
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    # `### Added` -> `### Added` stays; GitHub renders the Markdown as-is.
    return "\n".join(lines) + "\n"


def check(version, path):
    if not os.path.exists(path):
        print(f"::error::{path} is missing: every release needs its release notes (spec 16.37).")
        return 1
    text = open(path, encoding="utf-8").read()
    ents = entries(text)
    bad = [e[1] for e in ents if e[0] == "?"]
    if bad:
        for h in bad:
            print(f"::error::{path}: malformed entry heading '{h}' "
                  "(want '## <x.y.z> - <YYYY-MM-DD>' or '## Unreleased').")
        return 1
    unrel = find(ents, "Unreleased")
    if is_pre(version):
        if unrel is None or summary_and_items(unrel[2]) == ("", 0):
            if find(ents, base(version)) is None:
                print(f"::warning::{path} has no Unreleased changes for prerelease {version}; "
                      "its release page will say so.")
        print(f"release notes: prerelease {version} ok")
        return 0
    e = find(ents, version)
    date = "YYYY-MM-DD"
    if e is None:
        print(f"::error::{path} has no entry for release {version}.")
        print(HOWTO.format(version=version, date=date))
        return 1
    summary, items = summary_and_items(e[2])
    problems = []
    if not summary:
        problems.append("no summary paragraph under the heading")
    if items == 0:
        problems.append("no items")
    if unrel is not None and summary_and_items(unrel[2]) != ("", 0):
        problems.append("`## Unreleased` still has content: move it into the "
                        f"{version} entry (the release ships it)")
    if problems:
        for p in problems:
            print(f"::error::{path}, release {version}: {p}.")
        print(HOWTO.format(version=version, date=e[1].rsplit(" ", 1)[-1]))
        return 1
    print(f"release notes: {version} ok ({items} items)")
    return 0


def body(version, out, path):
    text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    ents = entries(text)
    if is_pre(version):
        e = find(ents, "Unreleased")
        if e is not None and summary_and_items(e[2]) != ("", 0):
            b = f"Prerelease of {base(version)}. Changes since the last release:\n\n" + body_text(e)
        elif find(ents, base(version)) is not None:
            b = f"Prerelease of {base(version)}.\n\n" + body_text(find(ents, base(version)))
        else:
            b = f"Prerelease of {base(version)}. No release notes were written for it.\n"
    else:
        e = find(ents, version)
        b = body_text(e) if e is not None else "No release notes.\n"
    b += ("\nThe same notes ship inside the release: `lw release-notes` shows them offline, "
          "and `lw self-update` lists what changed since your previous version.\n")
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(b)
    print(f"wrote {out}")
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "check":
        return check(argv[2].lstrip("v"), argv[3] if len(argv) > 3 else "CHANGELOG.md")
    if len(argv) >= 4 and argv[1] == "body":
        return body(argv[2].lstrip("v"), argv[3], argv[4] if len(argv) > 4 else "CHANGELOG.md")
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
