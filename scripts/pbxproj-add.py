#!/usr/bin/env python3
"""Add Swift files to the Glimmer (or GlimmerTests) target in Glimmer.xcodeproj.

The project lists files by hand (no synchronized folders), so a new source file
needs a PBXFileReference, a PBXBuildFile, a group entry and a Sources entry.

    scripts/pbxproj-add.py Glimmer/PlayStation/Foo.swift [more paths...]
    scripts/pbxproj-add.py --tests GlimmerTests/FooTests.swift

Paths are repo-relative. Idempotent: a file already in the project is skipped.
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "Glimmer.xcodeproj", "project.pbxproj")

TARGETS = {
    # group id, group path prefix, sources build phase id
    "app": ("A10000031", "Glimmer/", "A10000042"),
    "tests": ("D2000016", "GlimmerTests/", "D2000014"),
}


def uid(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def insert_after_line(text: str, anchor_regex: str, new_line: str) -> str:
    m = re.search(anchor_regex, text, re.M)
    if not m:
        sys.exit(f"anchor not found: {anchor_regex}")
    end = text.index("\n", m.end()) + 1
    return text[:end] + new_line + text[end:]


def main() -> None:
    args = sys.argv[1:]
    target = "app"
    if args and args[0] == "--tests":
        target, args = "tests", args[1:]
    group_id, prefix, phase_id = TARGETS[target]
    text = open(PBX).read()
    for path in args:
        if not path.startswith(prefix):
            sys.exit(f"{path} must start with {prefix}")
        rel = path[len(prefix):]
        name = os.path.basename(path)
        if f"path = {rel};" in text or f'path = "{rel}";' in text:
            print(f"skip (already present): {path}")
            continue
        ref, build = uid("ref:" + path), uid("build:" + path)
        qrel = f'"{rel}"' if re.search(r"[^A-Za-z0-9_./]", rel) else rel
        text = insert_after_line(
            text, r"^/\* Begin PBXBuildFile section \*/",
            f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n")
        text = insert_after_line(
            text, r"^/\* Begin PBXFileReference section \*/",
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f"path = {qrel}; sourceTree = \"<group>\"; }};\n")
        text = insert_after_line(
            text, rf"^\t\t{group_id} /\* [^*]+ \*/ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(",
            f"\t\t\t\t{ref} /* {name} */,\n")
        text = insert_after_line(
            text, rf"^\t\t{phase_id} /\* Sources \*/ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
                  rf"\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(",
            f"\t\t\t\t{build} /* {name} in Sources */,\n")
        print(f"added: {path}")
    open(PBX, "w").write(text)


if __name__ == "__main__":
    main()
