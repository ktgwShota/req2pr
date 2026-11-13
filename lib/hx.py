#!/usr/bin/env python3
"""req2pr の補助コマンド集（状態管理・ゲート判定・使用量記録・OpenCode 設定生成・PR 本文生成）。

bash から `python3 -I lib/hx.py <サブコマンド> ...` の形で呼ぶ。
標準ライブラリ + PyYAML のみに依存する。
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None

PHASE_LABELS = [
    ("plan", "① 設計（contract.md / qa-cases.yaml）・人の承認"),
    ("test", "② テスト作成（Red）"),
    ("implement", "③ 実装（Green）"),
    ("qa", "④ QAシート作成 → ⑤ QA実施・結果記入"),
    ("pr", "⑥ PR 作成"),
]
AGENTS = ["planner", "test-writer", "implementer", "qa-runner", "qa-reviewer"]


# --------------------------------------------------------------------------- utils
def now() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    sys.exit(code)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as e:
        if default is not None:
            return default
        die(f"JSON の形式が不正です: {path}: {e}")


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def load_yaml(path: Path):
    if yaml is None:
        die("PyYAML が必要です: pip install -r requirements.txt")
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except yaml.YAMLError as e:
        die(f"YAML の形式が不正です: {path}: {e}")


def split_globs(s: str) -> list[str]:
    return [g.strip() for g in (s or "").split(",") if g.strip()]


def glob_to_regex(glob: str) -> re.Pattern:
    """`**` はディレクトリをまたぐ、`*` はまたがない glob を正規表現に変換する。"""
    i, out = 0, []
    while i < len(glob):
        c = glob[i]
        if c == "*":
            if glob[i : i + 2] == "**":
                i += 2
                if glob[i : i + 1] == "/":
                    i += 1
                    out.append("(?:.*/)?")
                else:
                    out.append(".*")
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def matches_any(path: str, globs: list[str]) -> bool:
    p = path[2:] if path.startswith("./") else path
    return any(glob_to_regex(g).match(p) for g in globs)


def glob_to_permission(glob: str) -> str:
    """OpenCode のパーミッション（`*` が `/` もまたぐ）用のパターンに変換する。多少広めにマッチする。"""
    g = glob.replace("**/", "*").replace("**", "*")
    while "**" in g:
        g = g.replace("**", "*")
    return g


# --------------------------------------------------------------------------- state
def state_path(work: Path) -> Path:
    return work / "state.json"


def load_state(work: Path) -> dict:
    st = read_json(state_path(work), None)
    if st is None:
        die(f"state.json がありません: {work}（req2pr run から開始してください）")
    return st


def save_state(work: Path, st: dict) -> None:
    st["updated_at"] = now()
    write_json(state_path(work), st)


def get_path(d: dict, key: str):
    cur = d
    for k in key.split("."):
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def set_path(d: dict, key: str, value) -> None:
    ks = key.split(".")
    cur = d
    for k in ks[:-1]:
        cur = cur.setdefault(k, {})
    cur[ks[-1]] = value


def cmd_state(a) -> None:
    work = Path(a.work)
    if a.op == "init":
        st = {
            "issue": int(a.args[0]),
            "repo": a.args[1],
            "branch": a.args[2],
            "title": a.args[3] if len(a.args) > 3 else "",
            "harness_sha": a.args[4] if len(a.args) > 4 else "",
            "phase": "plan",
            "status": "running",
            "test_ref": "",
            "attempts": {},
            "gates": [],
            "started_at": now(),
        }
        save_state(work, st)
        return
    st = load_state(work)
    if a.op == "get":
        v = get_path(st, a.args[0])
        if v is None:
            print("")
        elif isinstance(v, (dict, list)):
            print(json.dumps(v, ensure_ascii=False))
        else:
            print(v)
    elif a.op == "set":
        v: object = a.args[1]
        set_path(st, a.args[0], v)
        save_state(work, st)
    elif a.op == "inc":
        v = int(get_path(st, a.args[0]) or 0) + 1
        set_path(st, a.args[0], v)
        save_state(work, st)
        print(v)
    elif a.op == "gate":
        gate, result = a.args[0], a.args[1]
        entry = {"at": now(), "gate": gate, "result": result}
        if len(a.args) > 2 and a.args[2]:
            entry["attempt"] = int(a.args[2])
        if len(a.args) > 3 and a.args[3]:
            entry["reason"] = a.args[3][:500]
        st.setdefault("gates", []).append(entry)
        save_state(work, st)
    else:
        die(f"不明な state 操作: {a.op}")


def usage_rows(work: Path) -> list[dict]:
    rows = []
    p = work / "usage.jsonl"
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows


def cmd_progress(a) -> None:
    """progress.md の STATUS 欄を state.json から再生成する（判断ログは保持）。"""
    work = Path(a.work)
    st = load_state(work)
    p = work / "progress.md"
    text = p.read_text(encoding="utf-8") if p.exists() else ""
    begin, end = "<!-- STATUS:BEGIN", "<!-- STATUS:END -->"
    log_part = ""
    if "## 判断ログ" in text:
        log_part = text[text.index("## 判断ログ") :]
    else:
        log_part = "## 判断ログ（各エージェントが末尾に追記）\n"

    order = [k for k, _ in PHASE_LABELS]
    cur = st.get("phase", "plan")
    status = st.get("status", "running")
    lines = []
    for key, label in PHASE_LABELS:
        done = (order.index(key) < order.index(cur)) if cur in order else False
        if status == "done":
            done = True
        mark = "x" if done else " "
        suffix = "  ← 現在" if key == cur and status != "done" else ""
        lines.append(f"- [{mark}] {label}{suffix}")

    last = (st.get("gates") or [])[-1:] or [None]
    last = last[0]
    last_s = "なし"
    if last:
        last_s = f"{last['gate']} = {last['result']}"
        if last.get("attempt"):
            last_s += f"（試行 {last['attempt']}）"
        if last.get("reason"):
            last_s += f" — {last['reason']}"

    rows = usage_rows(work)
    cost = sum(float(r.get("cost_usd") or 0) for r in rows)
    status_ja = {"running": "実行中", "halted": "中断", "done": "完了"}.get(status, status)
    nxt = {
        "plan": "planner が contract.md と qa-cases.yaml を作成し、人が承認する",
        "test": "test-writer が contract のテスト設計表どおりにテストを書き、Red を確認する",
        "implement": "implementer が feedback.md の失敗を解消し、test と lint を通す",
        "qa": "QAシートを作成し、qa-runner がブラウザで QA を実施する",
        "pr": "PR を作成する",
    }.get(cur, "")
    if status == "halted":
        nxt = f"中断中（理由: {st.get('halt_reason', '')}）。原因を確認して `req2pr run {st['issue']} --resume`"
    if status == "done":
        nxt = "完了。PR をレビューしてください"

    attempts = ", ".join(f"{k} {v}回" for k, v in (st.get("attempts") or {}).items()) or "なし"
    block = "\n".join(
        [
            "<!-- STATUS:BEGIN（ハーネスが毎回再生成します。エージェントは編集しないこと） -->",
            "## 現在の状態",
            f"- 状態: {status_ja}（工程: {cur}）",
            f"- 直近のゲート: {last_s}",
            f"- 実行回数: {attempts}",
            f"- API 料金（この issue 累計）: ${cost:.4f}",
            f"- 更新: {st.get('updated_at', '')}",
            "",
            "## 工程",
            *lines,
            "",
            "## 次のアクション",
            f"- {nxt}",
            end,
        ]
    )
    title = f"# 進捗 Issue #{st['issue']}: {st.get('title', '')}".rstrip(": ")
    p.write_text(f"{title}\n\n{block}\n\n{log_part.rstrip()}\n", encoding="utf-8")


# --------------------------------------------------------------------------- gates
def contract_sections(text: str) -> dict[str, str]:
    secs, cur, buf = {}, None, []
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            if cur:
                secs[cur] = "\n".join(buf)
            cur, buf = m.group(1), []
        elif cur:
            buf.append(line)
    if cur:
        secs[cur] = "\n".join(buf)
    return secs


def find_section(secs: dict[str, str], name: str) -> str | None:
    for k, v in secs.items():
        if k.startswith(name):
            return v
    return None


def strip_comments(s: str) -> str:
    return re.sub(r"<!--.*?-->", "", s, flags=re.S)


def parse_acs(text: str) -> list[str]:
    secs = contract_sections(text)
    body = strip_comments(find_section(secs, "完了要件") or "")
    return sorted(set(re.findall(r"\bAC-\d+\b", body)), key=lambda x: int(x.split("-")[1]))


def parse_tcs(text: str) -> list[tuple[str, list[str]]]:
    secs = contract_sections(text)
    body = strip_comments(find_section(secs, "テスト設計") or "")
    out = []
    for line in body.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cells and re.fullmatch(r"TC-\d+", cells[0]):
            acs = re.findall(r"AC-\d+", cells[1]) if len(cells) > 1 else []
            out.append((cells[0], acs))
    return out


def load_cases(work: Path) -> list[dict]:
    data = load_yaml(work / "qa" / "qa-cases.yaml") or {}
    return data.get("cases") or []


def cmd_gate(a) -> None:
    work = Path(a.work)
    problems: list[str] = []

    if a.kind == "contract":
        cpath = work / "contract.md"
        if not cpath.exists():
            die("contract.md が作成されていません")
        text = cpath.read_text(encoding="utf-8")
        if "<タイトル>" in text or "<ユーザー視点の振る舞い>" in text:
            problems.append("テンプレートのプレースホルダが残っています")
        secs = contract_sections(text)
        for name in ["完了要件", "テスト設計", "実装方針", "不明点"]:
            if find_section(secs, name) is None:
                problems.append(f"見出し「## {name}」がありません")
        acs = parse_acs(text)
        if not acs:
            problems.append("完了要件に AC-n がありません")
        tcs = parse_tcs(text)
        if not tcs:
            problems.append("テスト設計表に TC-n の行がありません")
        tc_ids = [t for t, _ in tcs]
        dup = sorted({t for t in tc_ids if tc_ids.count(t) > 1})
        if dup:
            problems.append(f"TC-ID が重複しています: {', '.join(dup)}")
        covered = {ac for _, a_ in tcs for ac in a_}
        for ac in acs:
            if ac not in covered:
                problems.append(f"{ac} に対応するテスト設計の行がありません")
        cases = load_cases(work)
        if not cases:
            problems.append("qa/qa-cases.yaml に cases がありません")
        ids = []
        for i, c in enumerate(cases, 1):
            if not isinstance(c, dict):
                problems.append(f"qa-cases の {i} 件目が不正です")
                continue
            for k in ["id", "ac", "title", "steps", "expected"]:
                if not c.get(k):
                    problems.append(f"qa-cases {c.get('id', i)}: {k} がありません")
            if c.get("steps") is not None and not isinstance(c.get("steps"), list):
                problems.append(f"qa-cases {c.get('id', i)}: steps はリストで書いてください")
            ids.append(c.get("id"))
        dup = sorted({x for x in ids if x and ids.count(x) > 1})
        if dup:
            problems.append(f"QA の id が重複しています: {', '.join(dup)}")
        qa_acs = {ac for c in cases if isinstance(c, dict) for ac in re.findall(r"AC-\d+", str(c.get("ac", "")))}
        for ac in acs:
            if ac not in qa_acs:
                problems.append(f"{ac} に対応する QA ケースがありません")
        unresolved = strip_comments(find_section(secs, "不明点") or "").strip()
        unresolved_items = [
            l for l in unresolved.splitlines() if l.strip().startswith("-") and l.strip() not in ("- なし", "-なし", "- 無し")
        ]
        if unresolved_items:
            print("UNRESOLVED")
            for l in unresolved_items:
                print(l)

    elif a.kind == "tc-ids":
        cpath = work / "contract.md"
        tc_ids = [t for t, _ in parse_tcs(cpath.read_text(encoding="utf-8"))]
        files = [l.strip() for l in sys.stdin if l.strip()]
        blob = ""
        for f in files:
            try:
                blob += Path(f).read_text(encoding="utf-8", errors="ignore") + "\n"
            except (FileNotFoundError, IsADirectoryError):
                pass
        for t in tc_ids:
            if not re.search(rf"\b{re.escape(t)}\b", blob):
                problems.append(f"{t} がテストコードに見つかりません（テスト名の先頭に TC-ID を付けてください）")
        if not files:
            problems.append("テストファイルが追加・変更されていません")

    elif a.kind == "qa":
        cases = load_cases(work)
        res = read_json(work / "qa" / "qa-results.json", {}) or {}
        by_id = {r.get("id"): r for r in res.get("results", []) if isinstance(r, dict)}
        for c in cases:
            r = by_id.get(c.get("id"))
            if not r:
                problems.append(f"{c.get('id')}: 未実施")
                continue
            result = str(r.get("result", "")).upper()
            if result != "OK":
                label = result if result in ("NG", "BLOCKED") else f"不正な結果値({r.get('result')})"
                problems.append(f"{c.get('id')}: {label} — {r.get('actual', '')}".rstrip(" —"))
    else:
        die(f"不明なゲート: {a.kind}")

    if problems:
        for p in problems:
            print(f"- {p}", file=sys.stderr)
        sys.exit(1)


def cmd_match(a) -> None:
    globs = split_globs(a.globs)
    for line in sys.stdin:
        p = line.rstrip("\n")
        if not p:
            continue
        hit = matches_any(p, globs)
        if hit != a.invert:
            print(p)


# --------------------------------------------------------------------------- QA results
def cmd_qa(a) -> None:
    work = Path(a.work)
    qa = work / "qa"
    if a.op == "apply-review":
        review = read_json(qa / "review.json", {}) or {}
        res = read_json(qa / "qa-results.json", {"results": []}) or {"results": []}
        by_id = {r.get("id"): r for r in res.get("results", [])}
        n = 0
        for o in review.get("overrides", []) or []:
            r = by_id.get(o.get("id"))
            if r is None:
                r = {"id": o.get("id"), "actual": ""}
                res.setdefault("results", []).append(r)
            r["result_by_runner"] = r.get("result")
            r["result"] = o.get("result", "NG")
            r["review_note"] = o.get("note", "")
            n += 1
        write_json(qa / "qa-results.json", res)
        print(f"レビューで {n} 件の判定を変更しました")
    elif a.op == "feedback":
        cases = {c.get("id"): c for c in load_cases(work)}
        res = read_json(qa / "qa-results.json", {}) or {}
        by_id = {r.get("id"): r for r in res.get("results", [])}
        out = ["# フィードバック: QA で不合格になったケース", "", "次のケースが期待どおりに動いていません。実装を修正してください。", ""]
        for cid, c in cases.items():
            r = by_id.get(cid)
            if r and str(r.get("result", "")).upper() == "OK":
                continue
            out.append(f"## {cid}（{c.get('ac')}）{c.get('title', '')}")
            out.append("- 手順:")
            out += [f"  {i}. {s}" for i, s in enumerate(c.get("steps") or [], 1)]
            out.append(f"- 期待結果: {c.get('expected')}")
            if r:
                out.append(f"- 実際: [{r.get('result')}] {r.get('actual', '')}")
                if r.get("review_note"):
                    out.append(f"- レビュー指摘: {r['review_note']}")
            else:
                out.append("- 実際: 未実施（QA 担当が到達できなかった）")
            out.append("")
        print("\n".join(out))
    else:
        die(f"不明な qa 操作: {a.op}")


# --------------------------------------------------------------------------- pricing / usage
def load_pricing(home: Path) -> dict:
    """単価表。ローカル設定（$REQ2PR_CONFIG/pricing.json）があればそれを優先する。"""
    local = Path(env("REQ2PR_CONFIG", str(Path.home() / ".config/req2pr"))) / "pricing.json"
    path = local if local.exists() else home / "config" / "pricing.json"
    return read_json(path, {"models": {}}) or {"models": {}}


def price_for(pricing: dict, model: str) -> dict:
    models = pricing.get("models", {})
    if model in models:
        return models[model]
    base = model.split("#", 1)[0]
    for pat, v in models.items():
        if fnmatch.fnmatchcase(base, pat):
            return v
    return {}


def walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)


def num(x) -> int:
    try:
        return int(x or 0)
    except (TypeError, ValueError):
        return 0


def extract_usage(objs: list) -> dict:
    """OpenCode の出力 JSON から tokens / cost を拾い集める（出力形式の差異に寛容にする）。"""
    seen: dict[str, dict] = {}
    for obj in objs:
        for d in walk(obj):
            t = d.get("tokens")
            if not isinstance(t, dict) or not any(k in t for k in ("input", "output")):
                continue
            key = str(d.get("id") or d.get("messageID") or json.dumps(t, sort_keys=True) + str(d.get("cost")))
            seen[key] = d
    tot = {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}
    cost = 0.0
    models = set()
    for d in seen.values():
        t = d["tokens"]
        cache = t.get("cache") if isinstance(t.get("cache"), dict) else {}
        tot["input"] += num(t.get("input"))
        tot["output"] += num(t.get("output"))
        tot["reasoning"] += num(t.get("reasoning"))
        tot["cache_read"] += num(cache.get("read", t.get("cache_read")))
        tot["cache_write"] += num(cache.get("write", t.get("cache_write")))
        try:
            cost += float(d.get("cost") or 0)
        except (TypeError, ValueError):
            pass
        m = d.get("modelID") or (d.get("model") if isinstance(d.get("model"), str) else None)
        if m:
            models.add(str(m))
    return {"tokens": tot, "cost_opencode": round(cost, 6), "messages": len(seen), "models_seen": sorted(models)}


def parse_json_stream(text: str) -> list:
    objs = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line[0] not in "{[":
            continue
        try:
            objs.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    if not objs:
        i = text.find("{")
        if i >= 0:
            try:
                objs.append(json.loads(text[i:]))
            except json.JSONDecodeError:
                pass
    return objs


LEDGER_FIELDS = [
    "at", "repo", "issue", "phase", "agent", "attempt", "provider", "model",
    "input", "output", "reasoning", "cache_read", "cache_write", "cost_usd", "cost_usd_opencode",
    "cost_source", "duration_s", "exit_code",
]


def cmd_usage(a) -> None:
    home = Path(env("REQ2PR_HOME", str(Path(__file__).resolve().parent.parent)))
    data_dir = Path(env("REQ2PR_DATA", str(Path.home() / ".local/share/req2pr")))
    ledger = data_dir / "usage-ledger.csv"

    if a.op == "record":
        work = Path(a.work)
        st = read_json(state_path(work), {}) or {}
        text = Path(a.log).read_text(encoding="utf-8", errors="ignore") if Path(a.log).exists() else ""
        objs = parse_json_stream(text)
        u = extract_usage(objs)
        sid_m = re.search(r"\bses_[A-Za-z0-9]+", text)
        sid = sid_m.group(0) if sid_m else ""
        if u["messages"] == 0 and sid:
            # 出力にトークン情報がない場合はセッションのエクスポートを試す（OpenCode のバージョン差異への保険）
            try:
                out = subprocess.run([env("OPENCODE_BIN", "opencode"), "export", sid], capture_output=True, text=True, timeout=60).stdout
                u2 = extract_usage(parse_json_stream(out))
                if u2["messages"]:
                    u = u2
            except Exception:
                pass
        model = a.model
        pr = price_for(load_pricing(home), model)
        t = u["tokens"]
        cost = (
            t["input"] * float(pr.get("input", 0))
            + (t["output"] + t["reasoning"]) * float(pr.get("output", 0))
            + t["cache_read"] * float(pr.get("cache_read", 0))
            + t["cache_write"] * float(pr.get("cache_write", 0))
        ) / 1_000_000
        cost_source = "pricing.json"
        if model.startswith("lmstudio/"):
            cost, cost_source = 0.0, "local"
        elif not any(float(pr.get(k, 0) or 0) for k in ("input", "output", "cache_read", "cache_write")):
            # 単価表が未記入（または該当なし）の場合は OpenCode が計算した料金を使う
            cost, cost_source = u["cost_opencode"], "opencode"
        row = {
            "at": now(),
            "repo": st.get("repo", ""),
            "issue": st.get("issue", ""),
            "phase": st.get("phase", ""),
            "agent": a.agent,
            "attempt": int(a.attempt),
            "provider": model.split("/", 1)[0],
            "model": model,
            "session": sid,
            "tokens": t,
            "cost_usd": round(cost, 6),
            "cost_usd_opencode": u["cost_opencode"],
            "cost_source": cost_source,
            "duration_s": int(a.duration),
            "exit_code": int(a.exit_code),
            "usage_found": u["messages"] > 0,
        }
        with open(work / "usage.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        data_dir.mkdir(parents=True, exist_ok=True)
        new = not ledger.exists()
        with open(ledger, "a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=LEDGER_FIELDS)
            if new:
                w.writeheader()
            flat = {k: row.get(k, "") for k in LEDGER_FIELDS}
            flat.update({k: t[k] for k in ("input", "output", "reasoning", "cache_read", "cache_write")})
            w.writerow(flat)
        if not row["usage_found"]:
            print("警告: トークン使用量を取得できませんでした（OpenCode の出力形式を確認してください）", file=sys.stderr)

    elif a.op == "summary":
        work = Path(a.work)
        rows = usage_rows(work)
        print(render_summary(rows, title=f"使用量サマリー Issue #{(read_json(state_path(work), {}) or {}).get('issue', '')}"))

    elif a.op == "report":
        if not ledger.exists():
            die(f"台帳がありません: {ledger}")
        with open(ledger, encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        if a.month:
            rows = [r for r in rows if r["at"].startswith(a.month)]
        print(f"# 使用量レポート {a.month or '（全期間）'}\n")
        for key, label in [("model", "モデル別"), ("agent", "エージェント別"), ("issue_key", "issue 別")]:
            agg: dict[str, list[float]] = {}
            for r in rows:
                k = f"{r['repo']}#{r['issue']}" if key == "issue_key" else r[key]
                v = agg.setdefault(k, [0, 0, 0, 0.0, 0])
                v[0] += 1
                v[1] += num(r["input"])
                v[2] += num(r["output"])
                v[3] += float(r["cost_usd"] or 0)
                v[4] += num(r["duration_s"])
            print(f"## {label}\n")
            print("| 対象 | 実行回数 | 入力tok | 出力tok | 料金(USD) | 時間 |")
            print("|---|---|---|---|---|---|")
            for k, v in sorted(agg.items(), key=lambda kv: -kv[1][3]):
                print(f"| {k} | {v[0]} | {v[1]:,} | {v[2]:,} | ${v[3]:.4f} | {fmt_dur(v[4])} |")
            print()
        total = sum(float(r["cost_usd"] or 0) for r in rows)
        print(f"**合計: ${total:.4f}（{len(rows)} 実行）**")
    else:
        die(f"不明な usage 操作: {a.op}")


def fmt_dur(s: int) -> str:
    s = int(s)
    return f"{s // 60}m{s % 60:02d}s"


def render_summary(rows: list[dict], title: str) -> str:
    agg: dict[tuple, dict] = {}
    for r in rows:
        k = (r.get("phase", ""), r.get("agent", ""), r.get("model", ""))
        v = agg.setdefault(k, {"n": 0, "in": 0, "out": 0, "cost": 0.0, "dur": 0})
        t = r.get("tokens") or {}
        v["n"] += 1
        v["in"] += num(t.get("input"))
        v["out"] += num(t.get("output"))
        v["cost"] += float(r.get("cost_usd") or 0)
        v["dur"] += num(r.get("duration_s"))
    out = [f"# {title}", "", "| 工程 | エージェント | モデル | 実行回数 | 入力tok | 出力tok | 料金(USD) | 時間 |", "|---|---|---|---|---|---|---|---|"]
    T = {"n": 0, "in": 0, "out": 0, "cost": 0.0, "dur": 0}
    for (ph, ag, mo), v in agg.items():
        out.append(f"| {ph} | {ag} | {mo} | {v['n']} | {v['in']:,} | {v['out']:,} | ${v['cost']:.4f} | {fmt_dur(v['dur'])} |")
        for k in T:
            T[k] += v[k]
    out.append(f"| **合計** | | | {T['n']} | {T['in']:,} | {T['out']:,} | **${T['cost']:.4f}** | {fmt_dur(T['dur'])} |")
    return "\n".join(out)


# --------------------------------------------------------------------------- OpenCode runtime config
DEFAULT_STEPS = {"planner": 80, "test-writer": 60, "implementer": 120, "qa-runner": 200, "qa-reviewer": 60}

READONLY_SHELL = [
    "ls *", "cat *", "head *", "tail *", "wc *", "grep *", "rg *", "find *", "pwd *", "tree *",
    "git status *", "git diff *", "git log *", "git show *",
]


def rule(action: str, resource: str, effect: str) -> dict:
    return {"action": action, "resource": resource, "effect": effect}


def agent_prompt(home: Path, name: str) -> tuple[str, str]:
    t = (home / "prompts" / "agents" / f"{name}.md").read_text(encoding="utf-8")
    desc = ""
    m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
    if m:
        dm = re.search(r"^description:\s*(.*)$", m.group(1), re.M)
        desc = dm.group(1).strip() if dm else ""
        t = t[m.end() :]
    return desc, t.strip() + "\n"


def cmd_opencode_config(a) -> None:
    home = Path(env("REQ2PR_HOME"))
    work = a.work.rstrip("/")
    test_perm = [glob_to_permission(g) for g in split_globs(env("TEST_GLOBS"))]
    local_id = env("LOCAL_MODEL_ID")
    local_ref = f"lmstudio/{local_id}#req2pr"
    models = {
        "planner": env("PLANNER_MODEL"),
        "test-writer": local_ref,
        "implementer": local_ref,
        "qa-runner": local_ref,
        "qa-reviewer": env("REVIEWER_MODEL"),
    }

    base = [
        rule("question", "*", "deny"),
        rule("subagent", "*", "deny"),
        rule("webfetch", "*", "deny"),
        rule("websearch", "*", "deny"),
        rule("external_directory", "*", "deny"),
        rule("read", "*.env", "deny"),
        rule("read", "*.env.*", "deny"),
        rule("read", "*.env.example", "allow"),
        rule("playwright_*", "*", "deny"),
        rule("edit", "*", "deny"),
        rule("edit", f"{work}/progress.md", "allow"),
        rule("shell", "*", "deny"),
        *[rule("shell", c, "allow") for c in READONLY_SHELL],
        rule("shell", "find * -delete*", "deny"),
        rule("shell", "find * -exec*", "deny"),
    ]
    run_test = [rule("shell", p, "allow") for p in (".req2pr/bin/test *", "./.req2pr/bin/test *", "bash .req2pr/bin/test *")]
    run_lint = [rule("shell", p, "allow") for p in (".req2pr/bin/lint *", "./.req2pr/bin/lint *", "bash .req2pr/bin/lint *")]

    per_agent = {
        "planner": [rule("edit", f"{work}/contract.md", "allow"), rule("edit", f"{work}/qa/qa-cases.yaml", "allow")],
        "test-writer": [*[rule("edit", p, "allow") for p in test_perm], *run_test],
        "implementer": [
            rule("edit", "*", "allow"),
            *[rule("edit", p, "deny") for p in test_perm],
            rule("edit", ".req2pr/*", "deny"),
            rule("edit", ".git/*", "deny"),
            rule("edit", ".env*", "deny"),
            rule("edit", "*/.env*", "deny"),
            rule("edit", f"{work}/progress.md", "allow"),
            *run_test,
            *run_lint,
        ],
        "qa-runner": [rule("playwright_*", "*", "allow"), rule("edit", f"{work}/qa/qa-results.json", "allow")],
        "qa-reviewer": [rule("edit", f"{work}/qa/review.json", "allow")],
    }

    agents = {}
    for name in AGENTS:
        desc, system = agent_prompt(home, name)
        steps = int(env(f"STEPS_{name.upper().replace('-', '_')}", str(DEFAULT_STEPS[name])))
        agents[name] = {
            "description": desc,
            "mode": "primary",
            "model": models[name],
            "system": system,
            "steps": steps,
            "permissions": per_agent[name],
        }

    instructions = [str(home / "prompts" / "common.md")]
    if env("REQ2PR_PROJECT_MD") and Path(env("REQ2PR_PROJECT_MD")).exists():
        instructions.append(env("REQ2PR_PROJECT_MD"))

    cfg = {
        "$schema": "https://opencode.ai/config.json",
        "model": local_ref,
        "default_agent": "implementer",
        "instructions": instructions,
        "providers": {
            "lmstudio": {
                "settings": {"baseURL": env("LMSTUDIO_BASE_URL")},
                "models": {
                    local_id: {
                        "name": "req2pr local coder",
                        "limit": {"context": int(env("LOCAL_CONTEXT_LENGTH", "65536")), "output": 16384},
                        "variants": [
                            {
                                "id": "req2pr",
                                "body": {"temperature": 0.7, "top_p": 0.8, "top_k": 20, "repeat_penalty": 1.05},
                            }
                        ],
                    }
                },
            }
        },
        "permissions": base,
        "agents": agents,
    }
    if a.agent == "qa-runner":
        cfg["mcp"] = {
            "servers": {
                "playwright": {
                    "type": "local",
                    "command": [
                        "npx", "-y", env("PLAYWRIGHT_MCP_PACKAGE", "@playwright/mcp@latest"),
                        "--browser", env("PLAYWRIGHT_BROWSER", "chrome"),
                        "--headless", "--isolated", "--output-dir", env("PLAYWRIGHT_OUTPUT_DIR"),
                    ],
                    "cwd": ".",
                    "codemode": False,
                }
            }
        }
    write_json(Path(a.out), cfg)


# --------------------------------------------------------------------------- PR body
def cmd_pr_body(a) -> None:
    home = Path(env("REQ2PR_HOME"))
    work = Path(a.work)
    st = load_state(work)
    repo, sha, docs = a.repo, a.sha, a.docs.rstrip("/")

    def blob(path: str, raw: bool = False) -> str:
        return f"https://github.com/{repo}/blob/{sha}/{path}" + ("?raw=true" if raw else "")

    text = (work / "contract.md").read_text(encoding="utf-8")
    acc = strip_comments(find_section(contract_sections(text), "完了要件") or "").strip()
    acc = re.sub(r"^- \[ \]", "- [x]", acc, flags=re.M)

    cases = load_cases(work)
    res = read_json(work / "qa" / "qa-results.json", {}) or {}
    by_id = {r.get("id"): r for r in res.get("results", [])}
    rows = ["| ID | AC | 確認内容 | 結果 | スクショ |", "|---|---|---|---|---|"]
    ok = 0
    for c in cases:
        r = by_id.get(c.get("id"), {})
        result = r.get("result", "-")
        ok += 1 if str(result).upper() == "OK" else 0
        shot = Path(str(r.get("screenshot") or "")).name
        img = f"![{c['id']}]({blob(f'{docs}/screenshots/{shot}', raw=True)})" if shot else "-"
        title = str(c.get("title", "")).replace("|", "\\|")
        rows.append(f"| {c['id']} | {c.get('ac', '')} | {title} | {result} | {img} |")

    usage = render_summary(usage_rows(work), title="").split("\n", 2)[-1].strip()
    tpl = (home / "templates" / "pr-body.md").read_text(encoding="utf-8")
    body = tpl.format(
        title=st.get("title", ""),
        issue=st.get("issue", ""),
        acceptance=acc or "（contract.md を参照）",
        qa_ok=ok,
        qa_total=len(cases),
        qa_table="\n".join(rows),
        qa_sheet_path=f"{docs}/qa-sheet.xlsx",
        qa_sheet_url=blob(f"{docs}/qa-sheet.xlsx"),
        contract_path=f"{docs}/contract.md",
        contract_url=blob(f"{docs}/contract.md"),
        usage=usage,
        harness_sha=st.get("harness_sha", "")[:12],
    )
    print(body)


# --------------------------------------------------------------------------- main
def main() -> None:
    ap = argparse.ArgumentParser(prog="hx")
    sp = ap.add_subparsers(dest="cmd", required=True)

    p = sp.add_parser("state")
    p.add_argument("work")
    p.add_argument("op", choices=["init", "get", "set", "inc", "gate"])
    p.add_argument("args", nargs="*")
    p.set_defaults(fn=cmd_state)

    p = sp.add_parser("progress")
    p.add_argument("work")
    p.set_defaults(fn=cmd_progress)

    p = sp.add_parser("gate")
    p.add_argument("work")
    p.add_argument("kind", choices=["contract", "tc-ids", "qa"])
    p.set_defaults(fn=cmd_gate)

    p = sp.add_parser("match")
    p.add_argument("globs")
    p.add_argument("--invert", action="store_true")
    p.set_defaults(fn=cmd_match)

    p = sp.add_parser("qa")
    p.add_argument("work")
    p.add_argument("op", choices=["apply-review", "feedback"])
    p.set_defaults(fn=cmd_qa)

    p = sp.add_parser("usage")
    p.add_argument("op", choices=["record", "summary", "report"])
    p.add_argument("--work", default="")
    p.add_argument("--agent", default="")
    p.add_argument("--attempt", default="0")
    p.add_argument("--model", default="")
    p.add_argument("--log", default="")
    p.add_argument("--duration", default="0")
    p.add_argument("--exit-code", dest="exit_code", default="0")
    p.add_argument("--month", default="")
    p.set_defaults(fn=cmd_usage)

    p = sp.add_parser("opencode-config")
    p.add_argument("--work", required=True)
    p.add_argument("--agent", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(fn=cmd_opencode_config)

    p = sp.add_parser("pr-body")
    p.add_argument("--work", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--docs", required=True)
    p.set_defaults(fn=cmd_pr_body)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
