import re
import sys
import html
import random
from pathlib import Path

import pandas as pd

args = [a for a in sys.argv[1:] if not a.startswith("--")]
SRC = Path(args[0]) if args else Path(".")
OUT = SRC / "clean"
OUT.mkdir(exist_ok=True)
problems = []


def need(path):
    if not (SRC / path).exists():
        sys.exit(f"Cannot find {SRC / path}. Run this script from the folder with A's files.")
    return SRC / path


# ---------------------------------------------------------------- key.js
key = need("key.js").read_text(encoding="utf-8", errors="replace")

# 525 trait pairs (same regex as A's notebook)
section = key.split("var measures = {", 1)[1].split("};", 1)[0]
pairs = re.findall(r'(\d+)\s*:\s*\["([^"]*)",\s*"([^"]*)"\]', section)
traits = pd.DataFrame(pairs, columns=["trait_id", "trait_low", "trait_high"])
traits["trait_id"] = traits["trait_id"].astype(int)
traits = traits[traits["trait_id"].between(1, 525)].sort_values("trait_id")


def clean_text(s):
    # key.js stores accents, apostrophes and emojis as HTML entities (e.g. 'H&#xE9;ctor', '&#129392;'): decode them
    return html.unescape(s).strip() if isinstance(s, str) else s


for col in ["trait_low", "trait_high"]:
    traits[col] = traits[col].map(clean_text)

# characters and their work (universe) names (same regex as A's notebook, plus the work name)
subjects = key.split("var subjects =", 1)[1]
rows = []
for work_code, body in re.findall(r'"([^"]+)"\s*:\s*\{\s*((?:(?!\n\s*"\w+"\s*:\s*\{).)*)', subjects, re.S):
    m = re.search(r'"name"\s*:\s*"([^"]*)"', body)
    work_name = m.group(1) if m else None
    for cid, name, _image in re.findall(r'(\d+)\s*:\s*\["([^"]+)",\s*"([^"]+)"\]', body):
        rows.append((f"{work_code}/{cid}", name, work_code, work_name))
named = pd.DataFrame(rows, columns=["character_code", "name", "work_code", "work_name"])
for col in ["name", "work_name"]:
    named[col] = named[col].map(clean_text)

# ---------------------------------------------------------------- scores
# skipinitialspace removes the hidden leading space in the column names (' 1' -> '1');
# blank lines at the end of the file are skipped automatically.
scores = pd.read_csv(need("characterScores.txt"), sep=",", skipinitialspace=True)
scores = scores.rename(columns={"character": "character_code"})
scores["character_code"] = scores["character_code"].astype(str).str.strip()

# ---------------------------------------------------------------- data-quality report
print("=== DATA-QUALITY REPORT ===")
print(f"trait pairs found: {len(traits)} (expected 525)")
is_emoji = lambda s: any(ord(ch) > 0x2000 for ch in str(s))
emoji_pairs = traits[traits["trait_low"].map(is_emoji) | traits["trait_high"].map(is_emoji)]
print(f"trait pairs where a pole is an EMOJI, not a word: {len(emoji_pairs)}  <- word-embedding models cannot embed these; tell A")
if len(traits) != 525:
    problems.append("trait pair count is not 525")
trait_cols = [c for c in scores.columns if c != "character_code"]
print(f"score columns: {len(trait_cols)} (expected 525)")
if len(trait_cols) != 525:
    problems.append("score column count is not 525")
dups = scores["character_code"].duplicated().sum()
print(f"scored characters: {len(scores)} | duplicate codes: {dups}")
if dups:
    problems.append("duplicate character codes in the score file")
vals = scores[trait_cols]
print(f"missing score cells: {int(vals.isna().sum().sum())} | min score {vals.min().min():g} | max score {vals.max().max():g}")
if vals.isna().any().any() or vals.min().min() < 0 or vals.max().max() > 100:
    problems.append("scores missing or outside 0-100")

unnamed = set(scores["character_code"]) - set(named["character_code"])
unscored = set(named["character_code"]) - set(scores["character_code"])
print(f"characters named in key.js: {len(named)} | scored but NOT named: {len(unnamed)} | named but NOT scored (dropped): {len(unscored)}")
if unnamed:
    problems.append("some scored characters have no name")

characters = named[named["character_code"].isin(scores["character_code"])].sort_values("character_code")
characters.to_csv(OUT / "characters.csv", index=False, encoding="utf-8")
traits.to_csv(OUT / "traits.csv", index=False, encoding="utf-8")

long_scores = scores.melt(id_vars="character_code", var_name="trait_id", value_name="score")
long_scores["trait_id"] = long_scores["trait_id"].astype(int)
long_scores.to_csv(OUT / "scores_long.csv", index=False, encoding="utf-8")
print(f"scores_long.csv rows: {len(long_scores)} (= {len(scores)} characters x {len(trait_cols)} traits)")

# ---------------------------------------------------------------- O*NET
onet = pd.read_csv(need("work_styles.csv"), encoding="utf-8-sig")
wi = onet[onet["Scale ID"] == "WI"].copy()          # keep Work Styles Impact; DR (distinctiveness rank) is not used
wi["Data Value"] = wi["Data Value"].astype(float)
n_jobs, n_traits = wi["O*NET-SOC Code"].nunique(), wi["Element Name"].nunique()
print(f"O*NET WI rows: {len(wi)} | jobs: {n_jobs} | traits: {n_traits} (expected 891 x 21 = {891 * 21})")
dup_pairs = wi.duplicated(["O*NET-SOC Code", "Element Name"]).sum()
print(f"duplicate (job, trait) pairs: {dup_pairs} | missing values: {int(wi['Data Value'].isna().sum())}")
print(f"importance range: {wi['Data Value'].min():g} to {wi['Data Value'].max():g} | negative values: {int((wi['Data Value'] < 0).sum())} (kept: they look like traits that work against the job)")
if dup_pairs or wi["Data Value"].isna().any():
    problems.append("O*NET duplicates or missing values")
if wi.groupby("Title")["O*NET-SOC Code"].nunique().max() > 1:
    problems.append("one job title maps to several O*NET codes")

jobs = wi[["O*NET-SOC Code", "Title"]].drop_duplicates().rename(columns={"O*NET-SOC Code": "onet_code", "Title": "title"})
jobs.sort_values("onet_code").to_csv(OUT / "jobs.csv", index=False, encoding="utf-8")
onet_traits = wi[["Element ID", "Element Name"]].drop_duplicates().sort_values("Element ID")[["Element Name"]].rename(columns={"Element Name": "name"})
onet_traits.to_csv(OUT / "onet_traits.csv", index=False, encoding="utf-8")
imp = wi[["O*NET-SOC Code", "Element Name", "Data Value"]].rename(columns={"O*NET-SOC Code": "onet_code", "Element Name": "trait_name", "Data Value": "importance"})
imp.to_csv(OUT / "importance.csv", index=False, encoding="utf-8")

# ---------------------------------------------------------------- optional placeholder similarity
if "--placeholder-similarity" in sys.argv:
    random.seed(1)
    sim = [(t, p, round(random.uniform(-1, 1), 3), round(random.uniform(-1, 1), 3), "RANDOM-TEST")
           for t in onet_traits["name"] for p in traits["trait_id"]]
    pd.DataFrame(sim, columns=["onet_trait", "trait_id", "sim_to_high", "sim_to_low", "method"]).to_csv(
        OUT / "similarity.csv", index=False, encoding="utf-8")
    print("\n!!! clean/similarity.csv holds RANDOM numbers (method = RANDOM-TEST). For testing only, never for the report. !!!")

print("\nfiles written to:", OUT.resolve())
if problems:
    print("\nPROBLEMS FOUND:", *problems, sep="\n  - ")
    sys.exit(1)
print("No blocking problems found.")
