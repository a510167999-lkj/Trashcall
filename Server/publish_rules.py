#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Trashcall Cloud Rules Publisher Script."""

import os
import json
import argparse
from datetime import datetime, timezone

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(BASE_DIR, "static")
RULES_FILE = os.path.join(STATIC_DIR, "rules_latest.json")
CUSTOM_RULES_FILE = os.path.join(BASE_DIR, "custom_rules.json")

EIGHT_DIGIT_AREA_CODES = {
    "0755", "0769", "0757", "0752", "0760", "0750", "0754", "0759",
    "0571", "0574", "0577", "0573", "0579", "0576", "0575",
    "0512", "0510", "0519", "0513", "0514", "0511", "0516", "0515", "0517", "0518", "0523", "0527",
    "0531", "0532", "0535", "0536", "0533", "0537", "0539",
    "0311", "0315", "0312", "0371", "0379",
    "0591", "0592", "0595",
    "0731", "0791", "0551", "0411", "0451", "0431", "0351",
    "0871", "0851", "0771", "0898", "0471", "0991"
}

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
        return int(digits)
    return None

def typical_national_length(digits: str) -> int:
    if digits.startswith("1"):
        return 11
    if digits.startswith("400") or digits.startswith("800"):
        return 10
    if digits.startswith("95"):
        return 8
    if digits.startswith("0"):
        if digits.startswith("010") or digits.startswith("02"):
            return 11
        if len(digits) >= 4:
            area = digits[:4]
            if area in EIGHT_DIGIT_AREA_CODES:
                return 12
            else:
                return 11
        return 12
    return len(digits) + 4

def sanitize_pattern(pattern: str) -> str:
    raw = pattern.strip()
    if not raw:
        return raw
    digits = "".join(c for c in raw if c.isdigit())
    if not digits:
        return raw
    target = typical_national_length(digits) if not digits.startswith("86") else 2 + typical_national_length(digits[2:])
    has_wildcard = any(c in "*?" for c in raw)
    if has_wildcard:
        cleaned = "".join(c for c in raw if c.isdigit() or c in "*?")
        if len(cleaned) > target:
            excess = len(cleaned) - target
            if all(c in "*?" for c in cleaned[-excess:]):
                return cleaned[:target]
        return raw
    else:
        missing = target - len(digits)
        if 1 <= missing <= 5:
            return digits + ("*" * missing)
        return digits

def expand_pattern(raw_pattern: str, max_allowed: int = 100000, default_cc: str = "86"):
    pattern = sanitize_pattern(raw_pattern)
    wildcards = sum(1 for c in pattern if c in "*?")
    if wildcards == 0:
        norm = normalize_phone(pattern, default_cc)
        return [norm] if norm else []

    total = 10 ** wildcards
    if total > max_allowed:
        raise ValueError(f"Pattern '{pattern}' too broad: {total} numbers > max {max_allowed}")

    start_str = pattern.replace("*", "0").replace("?", "0")
    end_str = pattern.replace("*", "9").replace("?", "9")
    start_num = normalize_phone(start_str, default_cc)
    end_num = normalize_phone(end_str, default_cc)
    if not start_num or not end_num or start_num > end_num:
        raise ValueError(f"Invalid pattern range: {pattern}")

    return list(range(start_num, end_num + 1))

def load_rules():
    if os.path.exists(RULES_FILE):
        with open(RULES_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {
        "version": datetime.now(timezone.utc).strftime("%Y.%m.%d.v1"),
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "description": "Trashcall 官方云端防骚扰与黑名单规则库",
        "min_client_version": "1.0.0",
        "added_blocking": [],
        "removed_blocking": [],
        "added_identifications": [],
        "removed_identifications": []
    }

def save_rules(data):
    os.makedirs(os.path.dirname(RULES_FILE), exist_ok=True)
    with open(RULES_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"✅ Rules published to {RULES_FILE}, version: {data.get('version')} ({len(data.get('added_blocking', []))} blocking, {len(data.get('added_identifications', []))} identifications)")

def save_custom_pattern(kind: str, pattern: str, label: str = ""):
    custom = {}
    if os.path.exists(CUSTOM_RULES_FILE):
        try:
            with open(CUSTOM_RULES_FILE, "r", encoding="utf-8") as f:
                custom = json.load(f)
        except Exception:
            pass
    if "blocking_patterns" not in custom:
        custom["blocking_patterns"] = []
    if "identification_patterns" not in custom:
        custom["identification_patterns"] = []

    if kind == "block":
        if pattern not in custom["blocking_patterns"]:
            custom["blocking_patterns"].append(pattern)
    elif kind == "identify":
        custom["identification_patterns"].append({"pattern": pattern, "label": label})

    with open(CUSTOM_RULES_FILE, "w", encoding="utf-8") as f:
        json.dump(custom, f, indent=2, ensure_ascii=False)

def sync_custom_rules(current_blocking: set, ident_dict: dict):
    if not os.path.exists(CUSTOM_RULES_FILE):
        return
    try:
        with open(CUSTOM_RULES_FILE, "r", encoding="utf-8") as f:
            custom = json.load(f)
    except Exception as e:
        print(f"⚠️ Failed to load {CUSTOM_RULES_FILE}: {e}")
        return

    for pat in custom.get("blocking_patterns", []):
        try:
            numbers = expand_pattern(pat)
            print(f"📦 Merged custom blocking pattern: {pat} ({len(numbers):,} numbers)")
            for num in numbers:
                current_blocking.add(num)
                ident_dict.pop(num, None)
        except Exception as e:
            print(f"⚠️ Failed to expand custom pattern '{pat}': {e}")

    for num in custom.get("blocking_numbers", []):
        current_blocking.add(num)
        ident_dict.pop(num, None)

    for item in custom.get("identification_patterns", []):
        pat = item.get("pattern")
        lbl = item.get("label", "自定义标记")
        if pat:
            try:
                numbers = expand_pattern(pat)
                for num in numbers:
                    if num not in current_blocking:
                        ident_dict[num] = lbl
            except Exception as e:
                print(f"⚠️ Failed to expand custom ident pattern '{pat}': {e}")

def main():
    parser = argparse.ArgumentParser(description="Publish Trashcall Rules")
    parser.add_argument("--add-block", nargs="+", type=int, help="Phone numbers to add to blocking list")
    parser.add_argument("--add-block-pattern", nargs="+", help="Wildcard patterns (e.g. 05712801****, 0552607****) to expand and block")
    parser.add_argument("--add-identify", nargs=2, action="append", metavar=("PHONE", "LABEL"), help="Phone number and label to add to identification")
    parser.add_argument("--add-identify-pattern", nargs=2, action="append", metavar=("PATTERN", "LABEL"), help="Pattern and label to add to identification")
    parser.add_argument("--sync-custom", action="store_true", help="Sync and expand all rules from custom_rules.json")
    parser.add_argument("--bump-version", action="store_true", help="Bump version tag to now")
    args = parser.parse_args()

    data = load_rules()
    data["updated_at"] = datetime.now(timezone.utc).isoformat()
    now_tag = datetime.now(timezone.utc).strftime("%Y.%m.%d.%H%M")
    data["version"] = f"rules.{now_tag}"

    current_blocking = set(data.get("added_blocking", []))
    ident_dict = {item["phone"]: item["label"] for item in data.get("added_identifications", [])}

    if args.sync_custom or args.bump_version or (not args.add_block and not args.add_block_pattern and not args.add_identify and not args.add_identify_pattern):
        sync_custom_rules(current_blocking, ident_dict)

    if args.add_block:
        for num in args.add_block:
            current_blocking.add(num)
            ident_dict.pop(num, None)

    if args.add_block_pattern:
        for pat in args.add_block_pattern:
            numbers = expand_pattern(pat)
            print(f"📦 Expanded pattern '{pat}' -> {len(numbers):,} numbers")
            for num in numbers:
                current_blocking.add(num)
                ident_dict.pop(num, None)
            save_custom_pattern("block", pat)

    if args.add_identify:
        for p_str, label in args.add_identify:
            num = int(p_str)
            if num not in current_blocking:
                ident_dict[num] = label

    if args.add_identify_pattern:
        for pat, label in args.add_identify_pattern:
            numbers = expand_pattern(pat)
            print(f"🏷️ Expanded identification pattern '{pat}' -> {len(numbers):,} numbers")
            for num in numbers:
                if num not in current_blocking:
                    ident_dict[num] = label
            save_custom_pattern("identify", pat, label)

    data["added_blocking"] = sorted(list(current_blocking))
    data["added_identifications"] = [{"phone": k, "label": ident_dict[k]} for k in sorted(ident_dict.keys())]

    save_rules(data)

if __name__ == "__main__":
    main()
