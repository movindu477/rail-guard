"""Exports mobile/lib/l10n/app_{en,si,ta}.arb to outputs/tables/translations_for_review.csv."""
import csv
import json
import os

base = os.path.join("mobile", "lib", "l10n")
with open(os.path.join(base, "app_en.arb"), encoding="utf-8") as f:
    en = json.load(f)
with open(os.path.join(base, "app_si.arb"), encoding="utf-8") as f:
    si = json.load(f)
with open(os.path.join(base, "app_ta.arb"), encoding="utf-8") as f:
    ta = json.load(f)

keys = [k for k in en.keys() if not k.startswith("@")]

out_dir = os.path.join("outputs", "tables")
os.makedirs(out_dir, exist_ok=True)
out_path = os.path.join(out_dir, "translations_for_review.csv")

with open(out_path, "w", encoding="utf-8-sig", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["string_key", "english", "sinhala", "tamil", "reviewed"])
    for k in keys:
        writer.writerow([k, en[k], si.get(k, ""), ta.get(k, ""), "no"])

print(f"Exported {len(keys)} strings to {out_path}")
