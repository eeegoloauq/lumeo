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


def items(release):
    """The untranslated lines: the app shows the translated ones."""
    return [
        " ".join("".join(e.itertext()).split())
        for e in release.iter()
        if e.tag in ("li", "p") and e.get(LANG) is None
    ]


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
        print("\n".join(f"- {line}" for r in chosen for line in items(r)))
    elif mode == "rpm":
        for release in releases:
            day = date.fromisoformat(release.get("date")).strftime("%a %b %d %Y")
            print(f"* {day} {PACKAGER} - {release.get('version')}-1")
            for line in items(release):
                print(textwrap.fill(line, 72, initial_indent="- ",
                                    subsequent_indent="  "))
            print()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(*sys.argv[1:])
