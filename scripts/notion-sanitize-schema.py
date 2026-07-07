#!/usr/bin/env python3
"""CA-1 (HU-10 #15): sanitize the Notion Tasks DB schema.

1. Migrate page select values from duplicated EN options to the canonical ES ones.
2. Drop duplicated "(1)" formula properties (Effort (1), Progress (1)).
3. Consolidate select options: remove EN duplicates from Energy / Impact / Mental Load.
4. Add the "Learning Session" option to Type (domain parity: LEARNING_SESSION).

Uses Notion API 2025-09-03 (data sources). Throttled to ~3 rps.
"""
import json
import os
import sys
import time
import urllib.request

TOKEN = os.environ["NOTION_TOKEN"]
TASKS_DS = "1bf8bc9c5d918171b7ea000b7e326082"
BASE = "https://api.notion.com/v1"
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Notion-Version": "2025-09-03",
    "Content-Type": "application/json",
}

ENERGY_EN_TO_ES = {"Sustained": "Sostenido", "Demanding": "Exigente",
                   "Execution": "Ejecución", "Automatic": "Automático", "Intense": "Intenso"}
IMPACT_EN_TO_ES = {"Moderate": "Moderado", "High": "Alto",
                   "Critical": "Crítico", "Irrelevant": "Irrelevante", "Low": "Bajo"}
MENTAL_EN_TO_ES = {"Routine": "Rutinario", "Focus": "Foco", "Analysis": "Análisis",
                   "Complex": "Complejo", "Abstract": "Abstracto"}
SELECT_MIGRATIONS = {"Energy": ENERGY_EN_TO_ES, "Impact": IMPACT_EN_TO_ES,
                     "Mental Load": MENTAL_EN_TO_ES}


def call(method, path, body=None, retries=5):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{BASE}{path}", data=data, headers=HEADERS, method=method)
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req) as res:
                return json.loads(res.read())
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = float(e.headers.get("Retry-After", "2"))
                time.sleep(wait)
                continue
            print(f"HTTP {e.code} on {method} {path}: {e.read().decode()[:500]}", file=sys.stderr)
            raise
    raise RuntimeError(f"rate-limited too many times on {path}")


def iter_pages():
    cursor = None
    while True:
        body = {"page_size": 100}
        if cursor:
            body["start_cursor"] = cursor
        res = call("POST", f"/data_sources/{TASKS_DS}/query", body)
        yield from res["results"]
        if not res.get("has_more"):
            return
        cursor = res["next_cursor"]


def migrate_page_values():
    patched = 0
    for page in iter_pages():
        props = page.get("properties", {})
        patch = {}
        for prop_name, mapping in SELECT_MIGRATIONS.items():
            sel = (props.get(prop_name) or {}).get("select")
            if sel and sel.get("name") in mapping:
                patch[prop_name] = {"select": {"name": mapping[sel["name"]]}}
        if patch:
            call("PATCH", f"/pages/{page['id']}", {"properties": patch})
            patched += 1
            time.sleep(0.35)
    print(f"pages migrated: {patched}")


def sanitize_schema():
    ds = call("GET", f"/data_sources/{TASKS_DS}")
    schema_patch = {"Effort (1)": None, "Progress (1)": None}
    for prop_name, mapping in SELECT_MIGRATIONS.items():
        options = ds["properties"][prop_name]["select"]["options"]
        kept = [{"id": o["id"], "name": o["name"], "color": o["color"]}
                for o in options if o["name"] not in mapping]
        schema_patch[prop_name] = {"select": {"options": kept}}
    type_options = ds["properties"]["Type"]["select"]["options"]
    type_kept = [{"id": o["id"], "name": o["name"], "color": o["color"]} for o in type_options]
    if not any(o["name"] == "Learning Session" for o in type_kept):
        type_kept.append({"name": "Learning Session", "color": "green"})
    schema_patch["Type"] = {"select": {"options": type_kept}}
    call("PATCH", f"/data_sources/{TASKS_DS}", {"properties": schema_patch})
    print("schema sanitized")


def verify():
    ds = call("GET", f"/data_sources/{TASKS_DS}")
    problems = []
    for stale in ("Effort (1)", "Progress (1)"):
        if stale in ds["properties"]:
            problems.append(f"property still present: {stale}")
    for prop_name, mapping in SELECT_MIGRATIONS.items():
        names = [o["name"] for o in ds["properties"][prop_name]["select"]["options"]]
        leftover = [n for n in names if n in mapping]
        if leftover:
            problems.append(f"{prop_name} still has EN options: {leftover}")
        print(f"{prop_name}: {names}")
    type_names = [o["name"] for o in ds["properties"]["Type"]["select"]["options"]]
    print(f"Type: {type_names}")
    if "Learning Session" not in type_names:
        problems.append("Type missing 'Learning Session'")
    if problems:
        print("PROBLEMS:\n" + "\n".join(problems), file=sys.stderr)
        sys.exit(1)
    print("verification OK")


if __name__ == "__main__":
    migrate_page_values()
    sanitize_schema()
    verify()
