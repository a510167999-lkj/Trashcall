#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the Trashcall identification seed database (no blocking list)."""

import os
import sqlite3
import subprocess
import glob
import sys
from datetime import datetime, timezone

try:
    import yaml
except ImportError:
    yaml = None

VCARDS_REPO = "https://github.com/metowolf/vCards.git"
CLONE_DIR = "/tmp/vCards_cache"
OUTPUT_DB = os.path.abspath(os.path.join(os.path.dirname(__file__), "../App/Resources/seed_database.sqlite"))
SEED_VERSION = datetime.now(timezone.utc).strftime("%Y.%m.%d.identify_only")
# Omitted from the default seed only. Users may add these numbers in-app;
# a seed may include them if they are explicitly sourced.
DEFAULT_SEED_OMISSIONS = {18964046784, 8618964046784}


def normalize_phone(raw_str, default_cc="86"):
    if not raw_str:
        return None
    raw = str(raw_str).strip()
    digits = "".join(c for c in raw if c.isdigit())
    if not digits:
        return None
    if raw.startswith("+"):
        pass
    elif raw.startswith("00") and len(digits) > 2:
        digits = digits[2:]
    else:
        if digits.startswith("0") and len(digits) > 3:
            digits = digits[1:]
        digits = f"{default_cc}{digits}"
    if 7 <= len(digits) <= 15:
        value = int(digits)
        if value in DEFAULT_SEED_OMISSIONS:
            return None
        return value
    return None


def ensure_vcards_repo():
    if yaml is None:
        print("⚠️ PyYAML not installed; skipping vCards fetch.")
        return False
    try:
        if os.path.exists(os.path.join(CLONE_DIR, ".git")):
            subprocess.run(["git", "-C", CLONE_DIR, "pull", "--depth", "1"], check=False)
        else:
            subprocess.run(["git", "clone", "--depth", "1", VCARDS_REPO, CLONE_DIR], check=True)
        return True
    except Exception as exc:
        print(f"⚠️ Could not fetch vCards: {exc}")
        return False


def parse_vcards():
    results = {}
    if yaml is None:
        return results
    category_mapping = {
        "房产中介": "房产中介",
        "证券保险": "理财保险",
        "金融银行": "银行信贷",
        "汽车行业": "汽车推销/4S店",
        "快递物流": "快递物流",
        "外卖订餐": "外卖配送",
        "电商购物": "电商客服",
        "政府机构": "政府官方政务",
        "通讯服务": "通信运营商",
    }
    data_dir = os.path.join(CLONE_DIR, "data")
    if not os.path.exists(data_dir):
        return results
    for cat_dir_name, label_prefix in category_mapping.items():
        cat_path = os.path.join(data_dir, cat_dir_name)
        if not os.path.exists(cat_path):
            continue
        for yaml_path in glob.glob(os.path.join(cat_path, "*.yaml")):
            try:
                with open(yaml_path, "r", encoding="utf-8") as handle:
                    doc = yaml.safe_load(handle)
                if not doc:
                    continue
                basic = doc.get("basic", {})
                org_name = basic.get("organization") or os.path.splitext(os.path.basename(yaml_path))[0]
                phones = basic.get("cellPhone", []) + basic.get("telephone", [])
                for phone in phones:
                    norm = normalize_phone(phone)
                    if norm:
                        results[norm] = f"{org_name} ({label_prefix})"
            except Exception:
                continue
    print(f"✅ Extracted {len(results)} enterprise numbers from metowolf/vCards.")
    return results


def add_range(dest, start, count, label):
    for i in range(count):
        phone = start + i
        if phone not in DEFAULT_SEED_OMISSIONS and 7 <= len(str(phone)) <= 15:
            dest[phone] = label


def generate_identification_ranges():
    identifications = {}
    add_range(identifications, 8695210000, 10000, "高频营销外呼 (9521号段)")
    add_range(identifications, 8695000000, 10000, "营销/骚扰 (950号段)")
    add_range(identifications, 864000880000, 5000, "中介理财推销 (400号段)")
    add_range(identifications, 8617000000000, 5000, "虚商营销外呼 (170号段)")
    add_range(identifications, 8617100000000, 5000, "虚商营销外呼 (171号段)")
    print(f"✅ Generated {len(identifications)} prefix identification numbers.")
    return identifications


def assert_integrity(conn, expected_count):
    cur = conn.cursor()
    blocking = cur.execute("SELECT COUNT(*) FROM blocking_numbers").fetchone()[0]
    if blocking != 0:
        raise SystemExit(f"integrity: blocking_numbers must be empty, got {blocking}")
    ident = cur.execute("SELECT COUNT(*) FROM identification_numbers").fetchone()[0]
    if ident != expected_count:
        raise SystemExit(f"integrity: identification count {ident} != {expected_count}")
    empty_labels = cur.execute(
        "SELECT COUNT(*) FROM identification_numbers WHERE label IS NULL OR trim(label) = ''"
    ).fetchone()[0]
    if empty_labels:
        raise SystemExit("integrity: empty identification labels")
    excluded_hits = cur.execute(
        f"SELECT COUNT(*) FROM identification_numbers WHERE phone_number IN ({','.join(str(n) for n in DEFAULT_SEED_OMISSIONS)})"
    ).fetchone()[0]
    if excluded_hits:
        raise SystemExit("integrity: default seed must not auto-write omitted numbers")
    bad_length = cur.execute(
        """
        SELECT COUNT(*) FROM identification_numbers
        WHERE length(CAST(phone_number AS TEXT)) < 7
           OR length(CAST(phone_number AS TEXT)) > 15
        """
    ).fetchone()[0]
    if bad_length:
        raise SystemExit(f"integrity: {bad_length} numbers outside E.164 length")
    unsorted = cur.execute(
        """
        SELECT COUNT(*) FROM (
            SELECT phone_number, LAG(phone_number) OVER (ORDER BY phone_number) AS prev
            FROM identification_numbers
        ) WHERE prev IS NOT NULL AND phone_number <= prev
        """
    ).fetchone()[0]
    if unsorted:
        raise SystemExit("integrity: identification_numbers are not strictly ascending")
    print(f"✅ Integrity OK: {ident} identification numbers, 0 blocking, default omissions absent.")


def build_sqlite_database(identification_map):
    os.makedirs(os.path.dirname(OUTPUT_DB), exist_ok=True)
    for path in (OUTPUT_DB, OUTPUT_DB + "-wal", OUTPUT_DB + "-shm"):
        if os.path.exists(path):
            os.remove(path)

    print(f"📦 Compiling identification database: {OUTPUT_DB}")
    conn = sqlite3.connect(OUTPUT_DB)
    cursor = conn.cursor()
    cursor.execute("PRAGMA journal_mode = DELETE;")
    cursor.execute("PRAGMA synchronous = FULL;")
    cursor.execute(
        "CREATE TABLE identification_numbers (phone_number INTEGER PRIMARY KEY, label TEXT NOT NULL);"
    )
    cursor.execute("CREATE TABLE blocking_numbers (phone_number INTEGER PRIMARY KEY);")
    cursor.execute(
        """
        CREATE TABLE user_rules (
            id TEXT PRIMARY KEY,
            pattern TEXT NOT NULL,
            action TEXT NOT NULL,
            label TEXT,
            count INTEGER NOT NULL,
            created_at REAL NOT NULL
        );
        """
    )
    cursor.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT);")
    cursor.execute("CREATE INDEX idx_identification_phone ON identification_numbers(phone_number ASC);")

    rows = sorted((n, label) for n, label in identification_map.items() if n not in DEFAULT_SEED_OMISSIONS)
    cursor.executemany(
        "INSERT OR REPLACE INTO identification_numbers (phone_number, label) VALUES (?, ?);",
        rows,
    )
    cursor.execute("INSERT INTO metadata (key, value) VALUES ('version', ?);", (SEED_VERSION,))
    cursor.execute("INSERT INTO metadata (key, value) VALUES ('auto_block_high_risk', 'false');")
    cursor.execute("INSERT INTO metadata (key, value) VALUES ('identification_count', ?);", (str(len(rows)),))
    cursor.execute("INSERT INTO metadata (key, value) VALUES ('blocking_count', '0');")
    conn.commit()
    assert_integrity(conn, len(rows))
    cursor.execute("VACUUM;")
    conn.close()
    print("==================================================")
    print("🎉 Identification database ready")
    print(f"   • Identified: {len(rows):,}")
    print(f"   • Version: {SEED_VERSION}")
    print(f"   • Size: {os.path.getsize(OUTPUT_DB) / 1024 / 1024:.2f} MB")
    print("==================================================")


def main():
    identifications = generate_identification_ranges()
    if ensure_vcards_repo():
        identifications.update(parse_vcards())
    for omitted in DEFAULT_SEED_OMISSIONS:
        identifications.pop(omitted, None)
    if not identifications:
        raise SystemExit("No identification numbers generated.")
    build_sqlite_database(identifications)


if __name__ == "__main__":
    main()
    sys.exit(0)
