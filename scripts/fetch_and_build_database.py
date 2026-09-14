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
SEED_VERSION = datetime.now(timezone.utc).strftime("%Y.%m.%d.%H%M%S.v3_410k")
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


def generate_landline_ranges():
    """Generates high-frequency telemarketing and broker landlines for major Chinese cities."""
    landlines = {}
    # Shanghai 021 (E.164: 8621 + 8 digits = 12 digits)
    add_range(landlines, 862131000000, 20000, "房产中介/推销座机 (上海 021-31)")
    add_range(landlines, 862151000000, 10000, "商业推销/电销座机 (上海 021-51)")
    add_range(landlines, 862163500000, 10000, "商业借贷/中介座机 (上海 021-6350)")
    add_range(landlines, 862180570000, 10000, "移动云呼/电销中继 (上海 021-8057)")

    # Beijing 010 (E.164: 8610 + 8 digits = 12 digits)
    add_range(landlines, 861053000000, 20000, "呼叫中心/外呼座机 (北京 010-53)")
    add_range(landlines, 861056000000, 10000, "商业推广/外呼座机 (北京 010-56)")

    # Shenzhen 0755 (E.164: 86755 + 8 digits = 13 digits)
    add_range(landlines, 8675533000000, 20000, "金融理财/助贷中介 (深圳 0755-33)")

    # Guangzhou 020 (E.164: 8620 + 8 digits = 12 digits)
    add_range(landlines, 862038000000, 10000, "商业营销/外呼座机 (广州 020-38)")

    # Hangzhou 0571 (E.164: 86571 + 8 digits = 13 digits)
    add_range(landlines, 8657126000000, 10000, "电商推广/推销座机 (杭州 0571-26)")
    add_range(landlines, 8657128000000, 30000, "保险电销/催收座机 (杭州 0571-28)")

    # Bengbu 0552 (E.164: 86552 + 7 digits = 12 digits)
    add_range(landlines, 865526070000, 10000, "商业推广/呼叫中心 (蚌埠 0552-60)")

    # Chengdu 028 (E.164: 8628 + 8 digits = 12 digits)
    add_range(landlines, 862860000000, 10000, "金融外包/电销座机 (成都 028-60)")
    add_range(landlines, 862868000000, 10000, "商业推广/外呼座机 (成都 028-68)")

    # Wuhan 027 (E.164: 8627 + 8 digits = 12 digits)
    add_range(landlines, 862787000000, 20000, "金融催收/外呼座机 (武汉 027-87)")

    # Chongqing 023 (E.164: 8623 + 8 digits = 12 digits)
    add_range(landlines, 862368000000, 30000, "网络小贷/催收座机 (重庆 023-68)")

    print(f"✅ Generated {len(landlines):,} high-frequency landline numbers.")
    return landlines


def generate_identification_ranges():
    """Generates 95/400 commercial outbound and virtual operator mobile numbers."""
    identifications = {}
    # 95 commercial outbound (8 digits, E.164: 8695xxxxxx = 10 digits)
    add_range(identifications, 8695210000, 10000, "高频营销外呼 (9521号段)")
    add_range(identifications, 8695200000, 10000, "商业呼叫中心 (9520号段)")
    add_range(identifications, 8695000000, 20000, "企业商业推销 (950号段)")
    add_range(identifications, 8695100000, 10000, "商业营销外呼 (951号段)")
    add_range(identifications, 8695700000, 10000, "金融炒股外呼 (9570号段)")
    add_range(identifications, 8695710000, 10000, "理财信贷外呼 (9571号段)")
    add_range(identifications, 8695770000, 10000, "商业营销催收 (9577号段)")

    # 400 commercial & collection outbound (10 digits, E.164: 86400xxxxxxx = 12 digits)
    add_range(identifications, 864000880000, 10000, "中介理财推销 (4000号段)")
    add_range(identifications, 864001880000, 10000, "商业营销推广 (4001号段)")
    add_range(identifications, 864006880000, 10000, "商业服务外呼 (4006号段)")
    add_range(identifications, 864007880000, 10000, "电销客服外呼 (4007号段)")
    add_range(identifications, 864008880000, 10000, "营销推广外呼 (4008号段)")
    add_range(identifications, 864009880000, 10000, "商业推广外呼 (4009号段)")

    # Virtual operator (MVNO) mobile outbound (11 digits, E.164: 8617xxxxxxxx / 8616xxxxxxxx = 13 digits)
    add_range(identifications, 8617000000000, 10000, "虚商营销外呼 (1700号段)")
    add_range(identifications, 8617050000000, 10000, "虚商营销外呼 (1705号段)")
    add_range(identifications, 8617100000000, 10000, "虚商营销外呼 (1710号段)")
    add_range(identifications, 8617150000000, 10000, "虚商营销外呼 (1715号段)")
    add_range(identifications, 8617180000000, 10000, "虚商营销外呼 (1718号段)")
    add_range(identifications, 8616200000000, 10000, "虚商电销外呼 (1620号段)")
    add_range(identifications, 8616500000000, 10000, "虚商电销外呼 (1650号段)")
    add_range(identifications, 8616700000000, 10000, "虚商高危电销卡 (1670号段)")
    add_range(identifications, 8616750000000, 10000, "虚商高危电销卡 (1675号段)")

    print(f"✅ Generated {len(identifications):,} commercial 95/400 and MVNO numbers.")
    return identifications


def generate_overseas_ranges():
    """Generates high-risk overseas spoofed VoIP and impersonation call ranges (+852/+886)."""
    overseas = {}
    # Hong Kong +852 (E.164: 852 + 8 digits = 11 digits)
    add_range(overseas, 85221000000, 10000, "境外高危外呼/冒充客服 (中国香港 +852-21)")
    add_range(overseas, 85230000000, 10000, "境外高危外呼/冒充客服 (中国香港 +852-30)")
    add_range(overseas, 85231000000, 10000, "境外高危外呼/冒充客服 (中国香港 +852-31)")

    # Taiwan +886 (E.164: 886 + 9 digits = 12 digits)
    add_range(overseas, 886900000000, 10000, "境外高危外呼/可疑来电 (中国台湾 +886-90)")

    print(f"✅ Generated {len(overseas):,} overseas high-risk VoIP numbers.")
    return overseas


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
    identifications.update(generate_landline_ranges())
    identifications.update(generate_overseas_ranges())
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
