#!/usr/bin/env bash
# ⑥ PR 作成。run.sh から呼ばれる（ROOT / N / WORK / REPO と設定値は export 済み）。
# QA 成果物を QA_DOCS_DIR/<N>/ にコピー → commit → push → Draft PR を作成（既にあれば本文を更新）。
set -euo pipefail
. "$REQ2PR_HOME/lib/lib.sh"
cd "$ROOT"

BRANCH=$(st get branch)
BASE=$(st get base)
TITLE=$(st get title)
DOCS="${QA_DOCS_DIR%/}/$N"

# ---- QA 成果物をコピー（.req2pr/ は git 管理外なので、PR に残すものだけをここに置く）
mkdir -p "$DOCS/screenshots"
cp "$WORK/contract.md" "$DOCS/contract.md"
cp "$WORK/qa/qa-cases.yaml" "$DOCS/qa-cases.yaml"
cp "$WORK/qa/qa-sheet.xlsx" "$DOCS/qa-sheet.xlsx"
[ -f "$WORK/qa/qa-results.json" ] && cp "$WORK/qa/qa-results.json" "$DOCS/qa-results.json"
for f in "$WORK"/qa/screenshots/*.png; do
  if [ -e "$f" ]; then cp "$f" "$DOCS/screenshots/"; fi
done

# ---- commit & push
git add -A
if git diff --cached --quiet; then
  warn "コミットする変更がありません"
else
  # shellcheck disable=SC2086
  git commit -q $GIT_COMMIT_FLAGS -m "${COMMIT_TYPE}: ${TITLE} (#${N})" -m "req2pr により作成。QA 成果物: ${DOCS}/"
fi
git push -q -u origin "$BRANCH"
SHA=$(git rev-parse HEAD)

# ---- PR 本文（画像・Excel のリンクはコミット SHA 固定）
hx pr-body --work "$WORK" --repo "$REPO" --sha "$SHA" --docs "$DOCS" > "$WORK/pr-body.md"

# 開いている PR だけを対象にする（reset で閉じた PR は再利用しない）
url=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json url -q '.[0].url' 2>/dev/null || true)
if [ -n "$url" ] && [ "$url" != "null" ]; then
  gh pr edit "$BRANCH" --repo "$REPO" --body-file "$WORK/pr-body.md" >/dev/null
  ok "既存の PR を更新しました: $url"
else
  url=$(gh pr create --repo "$REPO" --draft --base "$BASE" --head "$BRANCH" \
        --title "${COMMIT_TYPE}: ${TITLE} (#${N})" --body-file "$WORK/pr-body.md")
  ok "Draft PR を作成しました: $url"
fi
st set pr_url "$url"
