#!/usr/bin/env bash
# req2pr run <issue番号> [--resume] [--env-file <path>]
# 対象リポジトリのディレクトリで実行する。bin/req2pr から呼ばれる。
set -euo pipefail

# shellcheck source=lib.sh
. "$REQ2PR_HOME/lib/lib.sh"
# shellcheck source=load_config.sh
. "$REQ2PR_HOME/lib/load_config.sh"

N=""; RESUME=0; ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resume) RESUME=1 ;;
    --env-file) ENV_FILE="$2"; shift ;;
    --env-file=*) ENV_FILE="${1#*=}" ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) [ -z "$N" ] && N="$1" || die "不明な引数: $1" ;;
  esac
  shift
done
case "$N" in ''|*[!0-9]*) die "issue 番号を指定してください: req2pr run 123" ;; esac
if [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || die "--env-file が見つかりません: $ENV_FILE"
  ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
fi

ROOT=$(repo_root) || die "git リポジトリの中で実行してください"
cd "$ROOT"
detect_repo
load_config "$REPO_ID" "$ENV_FILE"
validate_config || exit 1
if [ -f "$REQ2PR_PROJECT_MD" ] && cmp -s "$REQ2PR_PROJECT_MD" "$REQ2PR_HOME/examples/project.md.example"; then
  die "project.md がサンプルのままです。プロジェクトに合わせて編集してください: $REQ2PR_PROJECT_MD"
fi
need gh "GitHub CLI をインストールし、gh auth login してください"
need "$OPENCODE_BIN" "OpenCode をインストールしてください"
need curl ""
"$PY" -I -c "import yaml, openpyxl" 2>/dev/null || die "Python 依存が不足しています: cd $REQ2PR_HOME && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"

export ROOT N REPO
WORK=".req2pr/$N"
export WORK
export PLAYWRIGHT_OUTPUT_DIR="$ROOT/$WORK/qa/screenshots"
REQ2PR_SHA=$(git -C "$REQ2PR_HOME" rev-parse --verify -q HEAD 2>/dev/null || echo unknown)

ensure_exclude
mkdir -p "$WORK/logs" "$WORK/qa/screenshots" "$WORK/templates"

# ---------------------------------------------------------------- 開始 / 再開
if [ "$RESUME" = 1 ]; then
  [ -f "$WORK/state.json" ] || die "$WORK/state.json がありません。--resume なしで開始してください"
  BRANCH=$(st get branch)
  BASE=$(st get base)
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || git switch "$BRANCH"
  st set status running
  st set attempts.qa_round 0     # 再開時は QA の周回上限をリセットする
  info "再開します: Issue #$N（工程: $(st get phase)）"
else
  [ -f "$WORK/state.json" ] && die "Issue #$N は作業中です。再開: req2pr run $N --resume ／ 最初からやり直す場合: req2pr reset $N"
  [ -z "$(git status --porcelain)" ] || die "作業ツリーに未コミットの変更があります。コミットまたは退避してから実行してください"
  BASE="${BASE_BRANCH:-}"
  if [ -z "$BASE" ]; then
    BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
    [ -n "$BASE" ] || BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    [ -n "$BASE" ] || BASE=main
  fi
  BRANCH="${BRANCH_PREFIX}${N}"
  git rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null \
    && die "ブランチ $BRANCH が既に存在します。やり直す場合: req2pr reset $N"
  # issue の取得を先に行う（失敗してもブランチや作業ファイルを残さない）
  gh issue view "$N" --repo "$REPO" --json number,title,body,comments,labels,url > "$WORK/logs/issue.tmp.json" \
    || { rm -rf "$WORK"; die "issue #$N を取得できませんでした（番号と gh auth status を確認してください）"; }
  git fetch -q origin "$BASE"
  git switch -q -c "$BRANCH" "origin/$BASE"
  mv "$WORK/logs/issue.tmp.json" "$WORK/issue.json"
  TITLE=$("$PY" -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["title"])' "$WORK/issue.json")
  hx state "$WORK" init "$N" "$REPO" "$BRANCH" "$TITLE" "$REQ2PR_SHA"
  st set base "$BASE"
  sed "s/<N>/$N/" "$REQ2PR_HOME/templates/progress.md" > "$WORK/progress.md"
  progress
  ok "開始: Issue #$N「$TITLE」 ブランチ $BRANCH（base: $BASE）"
fi
TITLE=$(st get title)
cp "$REQ2PR_HOME/templates/contract.md" "$REQ2PR_HOME/templates/qa-cases.yaml" "$WORK/templates/"
gen_wrappers
PHASE=$(st get phase)

# ---------------------------------------------------------------- ① 設計（Opus）+ 人の承認
if [ "$PHASE" = plan ]; then
  skip_plan=0
  # 再開時、設計が既にあって形式チェックに通るなら planner を再実行せず承認から始める
  if [ "$RESUME" = 1 ] && [ -f "$WORK/contract.md" ] && check_contract; then skip_plan=1; fi
  while true; do
    if [ "$skip_plan" = 0 ]; then
      retry planner "$MAX_PLAN" check_contract "issue の原文は $WORK/issue.json、テンプレートは $WORK/templates/ にあります。" \
        || halt contract
    fi
    skip_plan=0
    rc=0; approve || rc=$?
    case "$rc" in
      0) break ;;
      2) info "修正依頼を planner に渡して再設計します" ;;
      *) halt rejected ;;
    esac
  done
  rm -f "$WORK/feedback.md"
  if [ "${POST_CONTRACT_COMMENT:-1}" = 1 ]; then
    { printf '## req2pr: 承認済みの完了要件\n\n'; cat "$WORK/contract.md"; } > "$WORK/logs/contract-comment.md"
    gh issue comment "$N" --repo "$REPO" --body-file "$WORK/logs/contract-comment.md" >/dev/null || warn "issue へのコメントに失敗しました"
  fi
  set_phase test
  PHASE=test
fi

# ---------------------------------------------------------------- ② テスト作成（Red）
if [ "$PHASE" = test ]; then
  check_lmstudio
  retry test-writer "$MAX_RED" check_red "contract.md の「テスト設計」表の全行をテストにしてください。" || halt red
  git add -A
  # shellcheck disable=SC2086
  git commit -q $GIT_COMMIT_FLAGS -m "test: add failing tests for #$N (req2pr)"
  st set test_ref "$(git rev-parse HEAD)"
  set_phase implement
  PHASE=implement
fi

# ---------------------------------------------------------------- ③ 実装 → ④ QAシート作成 → ⑤ QA実施・結果記入
if [ "$PHASE" = implement ] || [ "$PHASE" = qa ]; then
  check_lmstudio
  round=$(st get attempts.qa_round); round=${round:-0}
  skip_impl=0
  # 再開時にすでに Green なら実装をスキップして QA から再開する
  if [ "$RESUME" = 1 ] && [ "$PHASE" = qa ] && check_green; then skip_impl=1; fi

  while [ "$round" -lt "$MAX_QA" ]; do
    if [ "$skip_impl" = 0 ]; then
      set_phase implement
      retry implementer "$MAX_GREEN" check_green || halt green
    fi
    skip_impl=0

    set_phase qa
    round=$(st inc attempts.qa_round)
    rm -f "$WORK/qa/qa-results.json" "$WORK/qa/review.json" "$WORK"/qa/screenshots/*.png
    "$PY" -I "$REQ2PR_HOME/lib/build_qa_sheet.py" --create "$WORK" >/dev/null     # ④ QAシート作成（結果欄は空）
    ok "④ QAシートを作成しました: $WORK/qa/qa-sheet.xlsx"

    start_app || halt app_start
    trap 'stop_app' EXIT
    oc qa-runner "QA対象のURL: $APP_URL
スクショは browser_take_screenshot の filename に「$WORK/qa/screenshots/<ケースID>.png」を指定してください（例: $WORK/qa/screenshots/QA-01.png）。
qa-results.json の screenshot にはファイル名だけ（例: QA-01.png）を書いてください。"
    stop_app
    trap - EXIT
    # 保存先がずれた場合の救済
    for f in .playwright-out/*.png QA-*.png; do
      if [ -e "$f" ]; then mv -f "$f" "$WORK/qa/screenshots/"; fi
    done

    if [ "${QA_REVIEW:-0}" = 1 ]; then
      oc qa-reviewer
      if [ -f "$WORK/qa/review.json" ]; then hx qa "$WORK" apply-review >&2; fi
    fi

    "$PY" -I "$REQ2PR_HOME/lib/build_qa_sheet.py" --fill "$WORK" >/dev/null      # ⑤ 結果記入
    if gate_out=$(hx gate "$WORK" qa 2>&1); then
      st gate qa pass "$round"
      ok "QA 合格（周回 $round）"
      set_phase pr
      PHASE=pr
      break
    fi
    st gate qa fail "$round" "$(printf '%s' "$gate_out" | head -c 400 | tr '\n' ' ')"
    warn "QA 不合格（周回 $round/$MAX_QA）:"
    printf '%s\n' "$gate_out" | sed 's/^/    /' >&2
    hx qa "$WORK" feedback > "$WORK/feedback.md"
    progress
  done
  [ "$PHASE" = pr ] || halt qa
fi

# ---------------------------------------------------------------- ⑥ PR 作成
if [ "$PHASE" = pr ]; then
  bash "$REQ2PR_HOME/lib/pr.sh" || halt pr
  st set status done
  progress
  notify "Issue #$N: 完了しました（PR: $(st get pr_url)）"
fi
