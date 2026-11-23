#!/usr/bin/env python3
"""Build a private Trashcall seed from a local OnePlus identification export."""

import argparse
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile


def callkit_number(raw: str) -> int | None:
    if not raw.isascii() or not raw.isdecimal():
        return None
    if raw.startswith("0086"):
        digits = raw[2:]
    elif raw.startswith("00"):
        return None  # This catalogue provides no reliable country data for other markets.
    elif raw.startswith("86") and len(raw) == 13 and raw[2] == "1":
        digits = raw
    else:
        national = raw[1:] if raw.startswith("0") else raw
        digits = f"86{national}"
    return int(digits) if 7 <= len(digits) <= 15 and int(digits[2:]) > 0 else None


def build(source: Path, seed: Path, output: Path) -> None:
    source, seed, output = (p.resolve() for p in (source, seed, output))
    if output in (source, seed) or output.exists():
        raise ValueError("Choose a new output path for the private build")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temp_name = tempfile.mkstemp(prefix=".seed-", suffix=".sqlite", dir=output.parent)
    os.close(descriptor)
    temporary = Path(temp_name)
    try:
        shutil.copyfile(seed, temporary)
        with sqlite3.connect(f"{source.as_uri()}?mode=ro", uri=True) as vendor, sqlite3.connect(temporary) as merged:
            version = vendor.execute(
                "SELECT value FROM metadata WHERE key = 'dictionary_version'"
            ).fetchone()
            if version is None or not version[0]:
                raise ValueError("Export has no dictionary version")
            merged.execute("""
                CREATE TABLE supplemental_identifications(
                    phone_number INTEGER PRIMARY KEY, label TEXT NOT NULL
                )
            """)
            query = """
                SELECT raw_number, label
                FROM recognition
                ORDER BY kind DESC, raw_number
            """
            input_count = invalid = 0

            def rows():
                nonlocal input_count, invalid
                for raw, value in vendor.execute(query):
                    input_count += 1
                    number = callkit_number(raw)
                    label = " ".join(value.replace("\0", "").split())
                    if number is None or not label:
                        invalid += 1
                    else:
                        yield number, label

            merged.executemany("INSERT OR IGNORE INTO supplemental_identifications VALUES (?, ?)", rows())
            count = merged.execute("SELECT COUNT(*) FROM supplemental_identifications").fetchone()[0]
            if not count:
                raise ValueError("Export contains no valid identification entries")
            merged.execute(
                "INSERT OR REPLACE INTO metadata VALUES ('supplemental_identification_version', ?)",
                (f"oneplus.{version[0]}.{count}",),
            )
            merged.commit()
            if merged.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                raise ValueError("Merged seed failed SQLite integrity check")
            overlap = merged.execute("""
                SELECT COUNT(*) FROM identification_numbers i JOIN supplemental_identifications s USING (phone_number)
            """).fetchone()[0]
        temporary.replace(output)
        print(f"source={input_count} invalid={invalid} deduplicated={input_count-invalid-count} oneplus={count} overlap={overlap}")
        print(output)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--seed", type=Path, default=Path(__file__).resolve().parents[1] / "App/Resources/seed_database.sqlite")
    args = parser.parse_args()
    build(args.source, args.seed, args.output)
