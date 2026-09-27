#!/usr/bin/env python3
"""Release notes from the AppStream file, the one place they are written.

    release-notes.py markdown VERSION   one release's items, for GitHub
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
        release = next(r for r in releases if r.get("version") == version)
        print("\n".join(f"- {line}" for line in items(release)))
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
