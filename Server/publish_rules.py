#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Trashcall Cloud Rules Publisher Script."""

import os
import json
import argparse

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

def is_complete_china_number(digits):
    return typical_national_length(digits) == len(digits) or (
        len(digits) >= 11 and not digits.startswith(("0", "1", "95", "400", "800"))
    )


def normalize_phone(raw_str, default_cc="86"):
    if not raw_str:
        return None
    raw = str(raw_str).strip()
    digits = "".join(c for c in raw if c.isascii() and c.isdigit())
    if not digits:
        return None
    if raw.startswith("+"):
        pass
    elif raw.startswith("00") and len(digits) > 2:
        digits = digits[2:]
    elif default_cc == "86" and digits.startswith("86") and is_complete_china_number(digits[2:]):
        pass
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
    if any(not ((c.isascii() and c.isdigit()) or c.isspace() or c in "+-().*?") for c in raw):
        raise ValueError(f"Invalid number pattern: {pattern}")
    cleaned = "".join(c for c in raw if (c.isascii() and c.isdigit()) or c in "+*?")
    if "+" in cleaned[1:]:
        raise ValueError(f"Invalid number pattern: {pattern}")
    digits = "".join(c for c in cleaned if c.isdigit())
    if not digits:
        return cleaned
    if (cleaned.startswith("+") and not digits.startswith("86")) or (
        cleaned.startswith("00") and not digits.startswith("0086")
    ):
        return cleaned

    national = digits[4:] if digits.startswith("0086") else digits[2:] if digits.startswith("86") else digits
    target = len(digits) - len(national) + typical_national_length(national)
    prefix_width = int(cleaned.startswith("+"))
    if any(c in "*?" for c in cleaned):
        excess = len(cleaned) - prefix_width - target
        if excess > 0 and all(c in "*?" for c in cleaned[-excess:]):
            return cleaned[:-excess]
    elif 1 <= target - len(digits) <= 5 and not is_complete_china_number(national):
        return cleaned + "*" * (target - len(digits))
    return cleaned


def expand_pattern(raw_pattern: str, max_allowed: int = 100000, default_cc: str = "86"):
    pattern = sanitize_pattern(raw_pattern)
    wildcards = sum(1 for c in pattern if c in "*?")
    if wildcards == 0:
        norm = normalize_phone(pattern, default_cc)
        return [norm] if norm else []

    pattern = "".join(c for c in pattern if c.isdigit() or c in "+*?")
    if not all(c in "*?" for c in pattern[-wildcards:]) or len(pattern) == wildcards:
        raise ValueError("Wildcards must appear at the end of the number")
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

def main():
    parser = argparse.ArgumentParser(description="Publish a complete Trashcall rules snapshot")
    parser.add_argument("--add-block", nargs="+", type=int, help="Verified single numbers to block")
    parser.add_argument("--add-block-pattern", nargs="+", help="Verified trailing-wildcard patterns to block")
    parser.add_argument("--add-identify", nargs=2, action="append", metavar=("PHONE", "LABEL"))
    parser.add_argument("--add-identify-pattern", nargs=2, action="append", metavar=("PATTERN", "LABEL"))
    parser.add_argument("--sync-custom", action="store_true", help="Rebuild from upstream and custom rules")
    parser.add_argument("--bump-version", action="store_true", help="Publish a new snapshot version")
    args = parser.parse_args()

    if args.add_block or args.add_block_pattern or args.add_identify or args.add_identify_pattern:
        if os.path.exists(CUSTOM_RULES_FILE):
            with open(CUSTOM_RULES_FILE, "r", encoding="utf-8") as f:
                custom = json.load(f)
        else:
            custom = {}

        def number(value):
            parsed = int(value)
            if not 1_000_000 <= parsed <= 999_999_999_999_999:
                raise ValueError(f"Invalid phone number: {value}")
            return parsed

        for phone in args.add_block or []:
            verified = custom.setdefault("verified_blocking_numbers", [])
            if number(phone) not in verified:
                verified.append(number(phone))
        for pattern in args.add_block_pattern or []:
            if not expand_pattern(pattern):
                raise ValueError(f"Invalid blocking pattern: {pattern}")
            verified = custom.setdefault("verified_blocking_patterns", [])
            if pattern not in verified:
                verified.append(pattern)
        for phone, label in args.add_identify or []:
            if not label.strip():
                raise ValueError("Identification label must not be empty")
            custom.setdefault("identification_numbers", []).append({"phone": number(phone), "label": label})
        for pattern, label in args.add_identify_pattern or []:
            if not expand_pattern(pattern) or not label.strip():
                raise ValueError(f"Invalid identification pattern or label: {pattern}")
            custom.setdefault("identification_patterns", []).append({"pattern": pattern, "label": label})
        temp_path = CUSTOM_RULES_FILE + ".tmp"
        with open(temp_path, "w", encoding="utf-8") as f:
            json.dump(custom, f, indent=2, ensure_ascii=False)
        os.replace(temp_path, CUSTOM_RULES_FILE)

    from auto_sync_upstream import run_sync
    run_sync(force=True)


if __name__ == "__main__":
    main()
