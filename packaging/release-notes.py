#!/usr/bin/env python3
"""Release notes from the AppStream file, the one place they are written.

    release-notes.py markdown VERSION   a release's items, for GitHub; a beta
                                        (X.Y.Z-beta.N) lists every beta of
                                        X.Y.Z up to it, as its page replaces
                                        theirs
    release-notes.py rpm                every release, as an RPM %changelog
"""
import sys
import textwrap
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path

METAINFO = (
    Path(__file__).resolve().parent.parent
    / "client/assets/dev.lumeo.lumeo.metainfo.xml"
)
PACKAGER = "Lumeo <67159275+eeegoloauq@users.noreply.github.com>"
LANG = "{http://www.w3.org/XML/1998/namespace}lang"


ORDER = ["", "Added", "Improved", "Fixed", "Removed"]


def text(element):
    return " ".join("".join(element.itertext()).split())


def groups(release):
    """The untranslated lines under their headings, the app showing the
    translated ones: a <p> before a <ul> heads it, and a release written
    before the headings has its lines under none."""
    found = {}
    description = release.find("description")
    children = [] if description is None else [
        e for e in description if e.get(LANG) is None]
    for n, element in enumerate(children):
        following = children[n + 1] if n + 1 < len(children) else None
        if element.tag == "ul":
            heading = children[n - 1] if n and children[n - 1].tag == "p" else None
            lines = [text(li) for li in element.iter("li") if li.get(LANG) is None]
            found.setdefault("" if heading is None else text(heading), []).extend(lines)
        elif element.tag == "p" and (following is None or following.tag != "ul"):
            found.setdefault("", []).append(text(element))
    return found


def merged(releases):
    """Every release's groups as one, in ORDER, newest first in each."""
    found = {}
    for release in releases:
        for heading, lines in groups(release).items():
            found.setdefault(heading, []).extend(lines)
    order = ORDER + [h for h in found if h not in ORDER]
    return [(h, found[h]) for h in order if found.get(h)]


def main(mode, version=None):
    releases = ET.parse(METAINFO).getroot().iter("release")
    if mode == "markdown":
        base, _, beta = version.partition("-beta.")
        chosen = [
            r for r in releases
            if r.get("version") == version
            or beta and r.get("version", "").startswith(f"{base}~beta.")
            and int(r.get("version").rpartition(".")[2]) <= int(beta)
        ]
        if not chosen:
            sys.exit(f"no release {version} in {METAINFO.name}")
        blocks = []
        for heading, lines in merged(chosen):
            block = "\n".join(f"- {line}" for line in lines)
            blocks.append(f"## {heading}\n\n{block}" if heading else block)
        print("\n\n".join(blocks))
    elif mode == "rpm":
        for release in releases:
            day = date.fromisoformat(release.get("date")).strftime("%a %b %d %Y")
            print(f"* {day} {PACKAGER} - {release.get('version')}-1")
            for line in (line for _, lines in merged([release]) for line in lines):
                print(textwrap.fill(line, 72, initial_indent="- ",
                                    subsequent_indent="  "))
            print()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(*sys.argv[1:])
