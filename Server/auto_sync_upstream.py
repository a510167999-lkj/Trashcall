#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Trashcall Upstream Auto-Sync Pipeline.
Fetches the latest open-source telephone records (metowolf/vCards),
computes incremental deltas, and publishes rules_latest.json for client auto-updates.
"""

import os
import sys
import glob
import json
import subprocess
from datetime import datetime, timezone

try:
    import yaml
except ImportError:
    yaml = None

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
UPSTREAM_DIR = os.path.join(BASE_DIR, "upstream")
VCARDS_DIR = os.path.join(UPSTREAM_DIR, "vCards")
STATIC_DIR = os.path.join(BASE_DIR, "static")
STATE_DIR = os.path.join(BASE_DIR, "state")
LOGS_DIR = os.path.join(BASE_DIR, "logs")

RULES_FILE = os.path.join(STATIC_DIR, "rules_latest.json")
STATE_FILE = os.path.join(STATE_DIR, "last_sync_state.json")

VCARDS_REPO = "https://github.com/metowolf/vCards.git"

# Numbers excluded from auto-blocking/auto-identification
OMISSIONS = {18964046784, 8618964046784}

CATEGORY_MAPPING = {
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

BLOCK_CATEGORIES = {"房产中介"}  # Can be tuned or expanded

def log(msg):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    line = f"[{now}] {msg}"
    print(line)
    try:
        os.makedirs(LOGS_DIR, exist_ok=True)
        with open(os.path.join(LOGS_DIR, "sync.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

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
        val = int(digits)
        if val in OMISSIONS:
            return None
        return val
    return None

def sync_git_upstream():
    os.makedirs(UPSTREAM_DIR, exist_ok=True)
    git_dir = os.path.join(VCARDS_DIR, ".git")
    mirrors = [
        VCARDS_REPO,
        "https://ghproxy.net/https://github.com/metowolf/vCards.git",
        "https://kgithub.com/metowolf/vCards.git",
    ]
    if not os.path.exists(git_dir):
        log("📦 Cloning metowolf/vCards upstream...")
        cloned = False
        for repo_url in mirrors:
            try:
                subprocess.run(["git", "clone", "--depth", "1", repo_url, VCARDS_DIR], check=True, timeout=30)
                cloned = True
                break
            except Exception as e:
                log(f"⚠️ Failed to clone from {repo_url}: {e}")
        if not cloned:
            log("❌ Could not clone vCards from any mirror; proceeding with empty or local cache.")
    else:
        log("🔄 Pulling latest changes from metowolf/vCards...")
        pulled = False
        try:
            subprocess.run(["git", "-C", VCARDS_DIR, "pull", "--depth", "1"], check=True, timeout=20)
            pulled = True
        except Exception as e:
            log(f"⚠️ Standard git pull failed: {e}. Trying git remote mirror...")
            try:
                subprocess.run(["git", "-C", VCARDS_DIR, "pull", "https://ghproxy.net/https://github.com/metowolf/vCards.git", "--depth", "1"], check=True, timeout=25)
                pulled = True
            except Exception as e2:
                log(f"⚠️ Mirror pull also failed: {e2}. Proceeding with existing local cache.")

    if os.path.exists(git_dir):
        try:
            res = subprocess.run(["git", "-C", VCARDS_DIR, "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
            commit = res.stdout.strip()
            log(f"📌 Upstream commit: {commit}")
            return commit
        except Exception:
            pass
    return "local_cache"

def parse_vcards():
    if yaml is None:
        log("❌ PyYAML is not installed; cannot parse vCards.")
        return {}, {}

    blocking_set = set()
    ident_dict = {}

    data_dir = os.path.join(VCARDS_DIR, "data")
    if not os.path.exists(data_dir):
        log(f"⚠️ Data directory {data_dir} not found.")
        return {}, {}

    for cat_dir_name, label_prefix in CATEGORY_MAPPING.items():
        cat_path = os.path.join(data_dir, cat_dir_name)
        if not os.path.exists(cat_path):
            continue
        is_block_cat = cat_dir_name in BLOCK_CATEGORIES

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
                    if not norm:
                        continue
                    if is_block_cat:
                        blocking_set.add(norm)
                    else:
                        ident_dict[norm] = f"{org_name} ({label_prefix})"
            except Exception:
                continue

    # Mutual exclusivity: if in blocking, remove from identification
    for b in blocking_set:
        ident_dict.pop(b, None)

    log(f"✅ Extracted {len(blocking_set)} blocking numbers and {len(ident_dict)} identification entries.")
    return blocking_set, ident_dict

def load_previous_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            log(f"⚠️ Failed to read previous state: {e}")
    return {}

def save_current_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)

def merge_custom_rules(blocking_set, ident_dict):
    custom_rules_file = os.path.join(BASE_DIR, "custom_rules.json")
    if not os.path.exists(custom_rules_file):
        default_custom = {
            "blocking_patterns": [
                "05712801****",
                "0552607****"
            ],
            "blocking_numbers": [],
            "identification_patterns": []
        }
        try:
            with open(custom_rules_file, "w", encoding="utf-8") as f:
                json.dump(default_custom, f, indent=2, ensure_ascii=False)
        except Exception:
            pass

    if os.path.exists(custom_rules_file):
        try:
            with open(custom_rules_file, "r", encoding="utf-8") as f:
                custom = json.load(f)
            from publish_rules import expand_pattern
            for pat in custom.get("blocking_patterns", []):
                try:
                    nums = expand_pattern(pat)
                    for n in nums:
                        blocking_set.add(n)
                        ident_dict.pop(n, None)
                    log(f"📦 Merged custom blocking pattern: {pat} ({len(nums):,} numbers)")
                except Exception as e:
                    log(f"⚠️ Failed to expand custom pattern {pat}: {e}")
            for num in custom.get("blocking_numbers", []):
                blocking_set.add(num)
                ident_dict.pop(num, None)
            for item in custom.get("identification_patterns", []):
                pat = item.get("pattern")
                lbl = item.get("label", "自定义标记")
                if pat:
                    try:
                        nums = expand_pattern(pat)
                        for n in nums:
                            if n not in blocking_set:
                                ident_dict[n] = lbl
                    except Exception as e:
                        log(f"⚠️ Failed to expand custom ident pattern {pat}: {e}")
        except Exception as e:
            log(f"⚠️ Failed to load custom rules: {e}")

def run_sync(force=False):
    log("🚀 Starting Trashcall Upstream Auto-Sync...")
    commit = sync_git_upstream()
    state = load_previous_state()
    prev_commit = state.get("last_commit")

    if not force and prev_commit == commit and os.path.exists(RULES_FILE):
        log("ℹ️ No new upstream commits since last sync. Rules are up to date.")
        return

    blocking_set, ident_dict = parse_vcards()
    merge_custom_rules(blocking_set, ident_dict)

    version_tag = datetime.now(timezone.utc).strftime("%Y.%m.%d.%H%M")
    new_version = f"rules.{version_tag}"

    sorted_blocking = sorted(list(blocking_set))
    sorted_identifications = [
        {"phone": k, "label": ident_dict[k]} for k in sorted(ident_dict.keys())
    ]

    payload = {
        "version": new_version,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "description": f"Trashcall 官方云端防骚扰与黄页规则库 (Git: {commit[:8]})",
        "min_client_version": "1.0.0",
        "added_blocking": sorted_blocking,
        "removed_blocking": [],
        "added_identifications": sorted_identifications,
        "removed_identifications": []
    }

    # Atomic write to static/rules_latest.json
    os.makedirs(STATIC_DIR, exist_ok=True)
    temp_file = RULES_FILE + ".tmp"
    with open(temp_file, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
    os.replace(temp_file, RULES_FILE)

    save_current_state({
        "last_commit": commit,
        "version": new_version,
        "updated_at": payload["updated_at"],
        "blocking_count": len(sorted_blocking),
        "identification_count": len(sorted_identifications)
    })

    log(f"🎉 Successfully published new rules version: {new_version} ({len(sorted_blocking)} blocking, {len(sorted_identifications)} identification entries).")

if __name__ == "__main__":
    force_flag = "--force" in sys.argv
    run_sync(force=force_flag)
