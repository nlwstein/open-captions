#!/usr/bin/env python3
"""The release's version and notes, from the conventional commits since the last release tag.

    Scripts/release.py next-version [--bump auto|patch|minor|major]   prints e.g. 0.2.0
    Scripts/release.py notes VERSION                                  prints Markdown release notes

Releases are tagged vX.Y.Z. With --bump auto (the default) the bump comes from the commits since
the newest such tag reachable from HEAD:

- a breaking change (`type!:` or a `BREAKING CHANGE:` footer) bumps major, except before 1.0.0,
  where it bumps minor;
- otherwise any `feat` bumps minor;
- otherwise patch.

With no release tag yet, the first version is 0.1.0. Standard library only; tested by
Scripts/test_release.py. Run by .github/workflows/release.yml.
"""
import argparse
import re
import subprocess
import sys

TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
SUBJECT = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<bang>!)?:\s*(?P<summary>.+)$")
BREAKING_FOOTER = re.compile(r"^BREAKING[ -]CHANGE:", re.MULTILINE)
FIRST = (0, 1, 0)

INSTALL = """\
## How to install

- Download `{ipa}` below. It is unsigned, so sign and install it with a sideloading tool such as
  [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or
  [Sideloadly](https://sideloadly.io), using your own Apple ID.
- It needs an iPhone or iPad with iOS 26 or later.
- On first launch the app downloads its speech models, about 1.1 GB. Everything runs on the phone
  after that.
- `{ipa}.sha256` is the file's SHA-256 checksum.
"""


class Commit:
    def __init__(self, sha, subject, body=""):
        self.sha, self.subject, self.body = sha, subject.strip(), body
        m = SUBJECT.match(self.subject)
        self.type = m["type"] if m else None
        self.scope = m["scope"] if m else None
        self.summary = m["summary"] if m else self.subject
        self.breaking = bool(m and m["bang"]) or bool(BREAKING_FOOTER.search(body))


def parse_version(text):
    m = TAG.match(text if text.startswith("v") else "v" + text)
    if not m:
        raise ValueError(f"not a version: {text}")
    return tuple(int(g) for g in m.groups())


def fmt(version):
    return ".".join(str(n) for n in version)


def bump_for(commits):
    if any(c.breaking for c in commits):
        return "major"
    if any(c.type == "feat" for c in commits):
        return "minor"
    return "patch"


def next_version(previous, commits, bump="auto"):
    """previous is a (major, minor, patch) tuple, or None when nothing has been released."""
    if previous is None:
        if bump == "auto":
            return FIRST
        previous = (0, 0, 0)
    if bump == "auto":
        bump = bump_for(commits)
        if bump == "major" and previous[0] == 0:
            bump = "minor"
    major, minor, patch = previous
    if bump == "major":
        return (major + 1, 0, 0)
    if bump == "minor":
        return (major, minor + 1, 0)
    if bump == "patch":
        return (major, minor, patch + 1)
    raise ValueError(f"unknown bump: {bump}")


def notes(version, previous, commits, ipa):
    groups = {"Features": [], "Fixes": [], "Other": []}
    for c in commits:
        group = "Features" if c.type == "feat" else "Fixes" if c.type == "fix" else "Other"
        # Sentence case, but leave words like "iOS" alone.
        line = c.summary if c.summary[1:2].isupper() else c.summary[:1].upper() + c.summary[1:]
        if c.scope:
            line = f"**{c.scope}:** {line}"
        if c.breaking:
            line = f"**Breaking:** {line}"
        groups[group].append(f"- {line} ({c.sha[:7]})")
    since = f"since v{fmt(previous)}" if previous else "in the first release"
    out = [f"Open Captions {fmt(version)}. Changes {since}:", ""]
    for title, lines in groups.items():
        if lines:
            out += [f"## {title}", "", *lines, ""]
    if not commits:
        out += ["No changes.", ""]
    out.append(INSTALL.format(ipa=ipa))
    return "\n".join(out)


# --- git -------------------------------------------------------------------------------------

def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def release_tags():
    """Versions of every vX.Y.Z tag reachable from HEAD, newest first."""
    versions = []
    for tag in git("tag", "--merged", "HEAD", "--list", "v*").split():
        try:
            versions.append(parse_version(tag))
        except ValueError:
            pass
    return sorted(versions, reverse=True)


def commits_since(previous):
    rev = f"v{fmt(previous)}..HEAD" if previous else "HEAD"
    raw = git("log", "--no-merges", "--format=%H%x1f%s%x1f%b%x1e", rev)
    commits = []
    for record in raw.split("\x1e"):
        fields = record.strip("\n").split("\x1f")
        if len(fields) == 3:
            commits.append(Commit(*fields))
    return commits


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    nv = sub.add_parser("next-version")
    nv.add_argument("--bump", default="auto", choices=["auto", "patch", "minor", "major"])
    n = sub.add_parser("notes")
    n.add_argument("version")
    n.add_argument("--ipa", help="the IPA's file name (default OpenCaptions-VERSION.ipa)")
    args = parser.parse_args(argv)

    if args.command == "next-version":
        tags = release_tags()
        previous = tags[0] if tags else None
        commits = commits_since(previous)
        if previous and not commits:
            sys.exit(f"nothing to release: no commits since v{fmt(previous)}")
        print(fmt(next_version(previous, commits, args.bump)))
    else:
        version = parse_version(args.version)
        # The newest release before this one, whether or not this version's tag exists yet.
        older = [t for t in release_tags() if t < version]
        previous = older[0] if older else None
        print(notes(version, previous, commits_since(previous), args.ipa or f"OpenCaptions-{fmt(version)}.ipa"))


if __name__ == "__main__":
    main()
