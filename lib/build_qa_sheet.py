#!/usr/bin/env python3
"""QAシート（Excel）を作成・記入する。

  build_qa_sheet.py --create <WORK>   qa-cases.yaml から結果欄が空のシートを作る（④ QAシート作成）
  build_qa_sheet.py --fill   <WORK>   qa-results.json の結果とスクショを記入する（⑤ 結果記入）

どちらも同じレイアウトで qa/qa-sheet.xlsx を書き出す（--fill は結果・スクショ入りで作り直す）。
"""
from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

try:
    import yaml
    from openpyxl import Workbook
    from openpyxl.drawing.image import Image as XLImage
    from openpyxl.formatting.rule import CellIsRule
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.utils import get_column_letter
    from openpyxl.worksheet.datavalidation import DataValidation
except ImportError as e:  # pragma: no cover
    sys.exit(f"依存パッケージが不足しています（pip install -r requirements.txt）: {e}")

THIN = Side(style="thin", color="C9CED6")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)
HEAD_FILL = PatternFill("solid", fgColor="2F3B52")
HEAD_FONT = Font(bold=True, color="FFFFFF")
WRAP = Alignment(wrap_text=True, vertical="top")
COLORS = {"OK": "C6EFCE", "NG": "FFC7CE", "BLOCKED": "FFEB9C"}
THUMB_W = 260  # px


def load(work: Path, fill: bool):
    cases_doc = yaml.safe_load((work / "qa" / "qa-cases.yaml").read_text(encoding="utf-8")) or {}
    cases = cases_doc.get("cases") or []
    results = {}
    executed_at = ""
    if fill:
        p = work / "qa" / "qa-results.json"
        if p.exists():
            doc = json.loads(p.read_text(encoding="utf-8"))
            results = {r.get("id"): r for r in doc.get("results", []) if isinstance(r, dict)}
            executed_at = doc.get("executed_at", "")
    state = {}
    sp = work / "state.json"
    if sp.exists():
        state = json.loads(sp.read_text(encoding="utf-8"))
    return cases, results, state, executed_at


def head(ws, cols):
    ws.append([c for c, _ in cols])
    for i, (_, w) in enumerate(cols, 1):
        cell = ws.cell(row=1, column=i)
        cell.fill, cell.font, cell.border = HEAD_FILL, HEAD_FONT, BORDER
        cell.alignment = Alignment(vertical="center", wrap_text=True)
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = "A2"


def add_thumb(ws, path: Path, anchor: str, width: int) -> float:
    img = XLImage(str(path))
    scale = width / img.width if img.width else 1
    img.width, img.height = int(img.width * scale), int(img.height * scale)
    ws.add_image(img, anchor)
    return img.height * 0.75  # px -> pt


def commit_sha() -> str:
    try:
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True).stdout.strip()
        return f"{sha}（＋未コミットの実装変更）" if dirty else sha
    except Exception:
        return ""


def build(work: Path, fill: bool) -> Path:
    cases, results, state, executed_at = load(work, fill)
    shots = work / "qa" / "screenshots"
    wb = Workbook()

    # ---- サマリー
    ws = wb.active
    ws.title = "サマリー"
    counts = {"OK": 0, "NG": 0, "BLOCKED": 0, "未実施": 0}
    for c in cases:
        r = str(results.get(c.get("id"), {}).get("result", "")).upper()
        counts[r if r in counts else "未実施"] += 1
    info = [
        ("Issue", f"#{state.get('issue', '')} {state.get('title', '')}"),
        ("リポジトリ", state.get("repo", "")),
        ("ブランチ", state.get("branch", "")),
        ("対象", commit_sha()),
        ("対象URL", os.environ.get("APP_URL", "")),
        ("作成日時", dt.datetime.now().strftime("%Y-%m-%d %H:%M")),
        ("実施日時", executed_at or (dt.datetime.now().strftime("%Y-%m-%d %H:%M") if fill else "（未実施）")),
        ("ケース数", len(cases)),
        ("OK", counts["OK"]),
        ("NG", counts["NG"]),
        ("BLOCKED", counts["BLOCKED"]),
        ("未実施", counts["未実施"]),
    ]
    ws.column_dimensions["A"].width = 16
    ws.column_dimensions["B"].width = 70
    ws.append(["QAシート"])
    ws["A1"].font = Font(bold=True, size=14)
    for k, v in info:
        ws.append([k, v])
        ws.cell(row=ws.max_row, column=1).font = Font(bold=True)
    ws.append([])
    ws.append(["完了要件", "合否（対応する QA ケースがすべて OK なら OK）"])
    for cell in ws[ws.max_row]:
        cell.fill, cell.font = HEAD_FILL, HEAD_FONT
    by_ac: dict[str, list[str]] = {}
    for c in cases:
        by_ac.setdefault(str(c.get("ac", "")), []).append(str(results.get(c.get("id"), {}).get("result", "")).upper())
    for ac, rs in by_ac.items():
        verdict = "OK" if rs and all(r == "OK" for r in rs) else ("未実施" if not any(rs) else "NG")
        ws.append([ac, verdict])
        if verdict in COLORS:
            ws.cell(row=ws.max_row, column=2).fill = PatternFill("solid", fgColor=COLORS[verdict])

    # ---- QAケース
    ws = wb.create_sheet("QAケース")
    cols = [("ID", 9), ("対応AC", 9), ("タイトル", 24), ("前提条件", 24), ("手順", 40), ("期待結果", 32),
            ("結果", 10), ("実際の挙動", 32), ("スクショ", 38), ("レビュー指摘", 24)]
    head(ws, cols)
    for i, c in enumerate(cases, start=2):
        r = results.get(c.get("id"), {})
        ws.append([
            c.get("id", ""), c.get("ac", ""), c.get("title", ""),
            "\n".join(f"・{p}" for p in (c.get("preconditions") or [])),
            "\n".join(f"{n}. {s}" for n, s in enumerate(c.get("steps") or [], 1)),
            c.get("expected", ""),
            str(r.get("result", "")).upper() if r.get("result") else "",
            r.get("actual", ""),
            "" if r.get("screenshot") else ("" if not fill else "（スクショなし）"),
            r.get("review_note", ""),
        ])
        for cell in ws[i]:
            cell.alignment, cell.border = WRAP, BORDER
        height = 15 * max(3, len(c.get("steps") or []) + 1)
        shot = shots / Path(str(r.get("screenshot"))).name if r.get("screenshot") else None
        if shot and shot.exists():
            height = max(height, add_thumb(ws, shot, f"I{i}", THUMB_W) + 6)
        ws.row_dimensions[i].height = height
    last = max(2, ws.max_row)
    dv = DataValidation(type="list", formula1='"OK,NG,BLOCKED"', allow_blank=True)
    ws.add_data_validation(dv)
    dv.add(f"G2:G{last}")
    for val, color in COLORS.items():
        ws.conditional_formatting.add(
            f"G2:G{last}", CellIsRule(operator="equal", formula=[f'"{val}"'], fill=PatternFill("solid", bgColor=color))
        )

    # ---- 証跡
    ws = wb.create_sheet("証跡")
    ws.column_dimensions["A"].width = 120
    row = 1
    for c in cases:
        r = results.get(c.get("id"), {})
        ws.cell(row=row, column=1, value=f"{c.get('id')} {c.get('title', '')}  —  結果: {r.get('result', '未実施')}").font = Font(bold=True)
        row += 1
        shot = shots / Path(str(r.get("screenshot"))).name if r.get("screenshot") else None
        if shot and shot.exists():
            h = add_thumb(ws, shot, f"A{row}", 900)
            ws.row_dimensions[row].height = h + 6
        else:
            ws.cell(row=row, column=1, value="（スクショなし）")
        row += 2

    out = work / "qa" / "qa-sheet.xlsx"
    out.parent.mkdir(parents=True, exist_ok=True)
    wb.save(out)
    return out


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in ("--create", "--fill"):
        sys.exit("usage: build_qa_sheet.py --create|--fill <WORK>")
    out = build(Path(sys.argv[2]), fill=sys.argv[1] == "--fill")
    print(out)


if __name__ == "__main__":
    main()
