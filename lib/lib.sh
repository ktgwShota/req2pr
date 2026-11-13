# shellcheck shell=bash
# req2pr 共通関数。bash 3.2（macOS 標準）でも動くように書いている。

# $REQ2PR_HOME/.venv があればその Python を使う
if [ -z "${REQ2PR_PYTHON:-}" ] && [ -n "${REQ2PR_HOME:-}" ] && [ -x "$REQ2PR_HOME/.venv/bin/python" ]; then
  REQ2PR_PYTHON="$REQ2PR_HOME/.venv/bin/python"
fi
PY="${REQ2PR_PYTHON:-python3}"

# LM Studio アプリ付属の lms（~/.lmstudio/bin）が PATH に無ければ追加する
if ! command -v lms >/dev/null 2>&1 && [ -x "$HOME/.lmstudio/bin/lms" ]; then
  PATH="$PATH:$HOME/.lmstudio/bin"; export PATH
fi

# ---------------------------------------------------------------- 出力
if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi
info() { printf '%s\n' "${C_BLU}[req2pr]${C_RST} $*" >&2; }
ok()   { printf '%s\n' "${C_GRN}[req2pr] ✔${C_RST} $*" >&2; }
warn() { printf '%s\n' "${C_YEL}[req2pr] !${C_RST} $*" >&2; }
err()  { printf '%s\n' "${C_RED}[req2pr] ✘${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }

hx() { "$PY" -I "$REQ2PR_HOME/lib/hx.py" "$@"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。$2"
}

# ---------------------------------------------------------------- リポジトリ
repo_root() { git rev-parse --show-toplevel 2>/dev/null; }

# REPO（owner/repo）と REPO_ID（owner__repo）を設定する
detect_repo() {
  local url path
  url=$(git config --get remote.origin.url 2>/dev/null) || die "origin リモートがありません（対象リポジトリのディレクトリで実行してください）"
  case "$url" in
    git@*:*) path="${url#*:}" ;;
    ssh://*|https://*|http://*) path="${url#*://}"; path="${path#*/}" ;;
    *) path="$url" ;;
  esac
  path="${path%.git}"; path="${path%/}"
  REPO="$path"
  REPO_ID=$(printf '%s' "$REPO" | sed 's#/#__#g')
  export REPO REPO_ID
}

# .req2pr/ などを git 管理外にする（.gitignore は変更しない）
ensure_exclude() {
  local ex
  ex="$(git rev-parse --git-path info/exclude)"
  mkdir -p "$(dirname "$ex")"; touch "$ex"
  for p in ".req2pr/" ".playwright-out/"; do
    grep -qxF "$p" "$ex" || printf '%s\n' "$p" >> "$ex"
  done
}

# git status から変更・追加ファイルを列挙（.req2pr は exclude 済み）
changed_files() {
  git status --porcelain -uall | while IFS= read -r line; do
    p="${line:3}"
    case "$p" in *" -> "*) p="${p##* -> }" ;; esac
    p="${p%\"}"; p="${p#\"}"
    printf '%s\n' "$p"
  done
}

# 指定ファイルを HEAD（または指定コミット）の状態に戻す。未追跡ファイルは削除する
revert_paths() {
  local ref="$1"; shift
  local f
  for f in "$@"; do
    [ -n "$f" ] || continue
    if git cat-file -e "$ref:$f" 2>/dev/null; then
      git checkout -q "$ref" -- "$f"
    else
      rm -f -- "$f"
    fi
  done
}

# .req2pr/bin/test, .req2pr/bin/lint を生成する
gen_wrappers() {
  mkdir -p .req2pr/bin
  {
    printf '#!/usr/bin/env bash\n# req2pr が生成（TEST_CMD）。編集しないこと\n'
    printf 'cd "$(git rev-parse --show-toplevel)" || exit 2\n'
    printf '%s\n' "$TEST_CMD"
  } > .req2pr/bin/test
  {
    printf '#!/usr/bin/env bash\n# req2pr が生成（LINT_CMD）。編集しないこと\n'
    printf 'cd "$(git rev-parse --show-toplevel)" || exit 2\n'
    printf '%s\n' "$LINT_CMD"
  } > .req2pr/bin/lint
  chmod +x .req2pr/bin/test .req2pr/bin/lint
}

# ---------------------------------------------------------------- 状態
st()       { hx state "$WORK" "$@"; }
progress() { hx progress "$WORK" || true; }
set_phase() { st set phase "$1"; progress; }

halt() {
  st set status halted
  st set halt_reason "$1"
  progress
  notify "Issue #$N: 中断（$1）"
  err "中断しました（理由: $1）。状況: req2pr status $N / 再開: req2pr run $N --resume"
  err "  最初からやり直す場合: req2pr reset $N"
  exit 1
}

notify() {
  local msg="$1"
  info "$msg"
  if [ -n "${NOTIFY_CMD:-}" ]; then
    # shellcheck disable=SC2086
    $NOTIFY_CMD "$msg" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"req2pr\"" >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------- LM Studio
check_lmstudio() {
  local models
  models=$(curl -sf --max-time 5 "$LMSTUDIO_BASE_URL/models" 2>/dev/null || true)
  if [ -z "$models" ]; then
    if command -v lms >/dev/null 2>&1; then
      info "LM Studio サーバーを起動します（lms server start）"
      lms server start >/dev/null 2>&1 || true
      sleep 3
      models=$(curl -sf --max-time 5 "$LMSTUDIO_BASE_URL/models" 2>/dev/null || true)
    fi
    [ -n "$models" ] || die "LM Studio に接続できません: $LMSTUDIO_BASE_URL（LM Studio のサーバーを起動してください）"
  fi
  local loaded=0
  if command -v lms >/dev/null 2>&1; then
    # /v1/models は未ロード（JIT）のモデルも返すことがあるので、lms ps で実際の読み込み状態を見る
    lms ps 2>/dev/null | grep -qF "$LOCAL_MODEL_ID" && loaded=1
  elif printf '%s' "$models" | grep -qF "\"$LOCAL_MODEL_ID\""; then
    loaded=1
  fi
  if [ "$loaded" = 0 ]; then
    if command -v lms >/dev/null 2>&1; then
      info "モデルをロードします: $LOCAL_MODEL_ID（context $LOCAL_CONTEXT_LENGTH）"
      lms load "$LOCAL_MODEL_ID" --context-length "$LOCAL_CONTEXT_LENGTH" --identifier "$LOCAL_MODEL_ID" </dev/null >/dev/null 2>&1 \
        || warn "lms load に失敗しました。LM Studio でモデルを手動でロードしてください"
    else
      warn "LM Studio で $LOCAL_MODEL_ID が見つかりません（ロード済みか、LOCAL_MODEL_ID が正しいか確認してください）"
    fi
  fi
}

# ---------------------------------------------------------------- OpenCode 実行
model_for() {
  case "$1" in
    planner) printf '%s' "$PLANNER_MODEL" ;;
    qa-reviewer) printf '%s' "$REVIEWER_MODEL" ;;
    *) printf '%s' "lmstudio/$LOCAL_MODEL_ID" ;;
  esac
}

# oc <agent> <追加の指示>
# 工程ごとに OpenCode を新しいプロセス（--standalone）で起動し、終わったら使用量を記録する
oc() {
  local agent="$1" extra="${2:-}"
  local attempt cfg out errf model t0 rc=0 pid wd prompt dotcfg=""
  attempt=$(st inc "attempts.$agent")
  mkdir -p "$WORK/logs"
  cfg="$ROOT/$WORK/logs/opencode.$agent.json"
  out="$WORK/logs/$agent.$attempt.jsonl"
  errf="$WORK/logs/$agent.$attempt.err"
  model=$(model_for "$agent")
  hx opencode-config --work "$WORK" --agent "$agent" --out "$cfg"

  local fbnote=""
  if [ -f "$WORK/feedback.md" ]; then
    fbnote="前回の失敗内容が $WORK/feedback.md にあります。最初に読んで、すべて対処してください。"
  fi
  prompt="あなたは req2pr の「$agent」です。Issue #$N を担当します。
WORK=$WORK （作業ファイルの場所）
試行: $attempt 回目
$fbnote
$extra
エージェント定義の手順に従って作業し、終わったら $WORK/progress.md の判断ログに追記して終了してください。"

  if [ "$OPENCODE_CONFIG_MODE" = "dotdir" ]; then
    # OPENCODE_CONFIG が効かない環境向け: 対象リポジトリの .opencode/ に一時的に置く（exclude 済み）
    if [ -e .opencode/opencode.json ] || [ -e .opencode/opencode.jsonc ]; then
      die "対象リポジトリに .opencode/opencode.json(c) が既にあるため dotdir モードは使えません"
    fi
    mkdir -p .opencode; cp "$cfg" .opencode/opencode.jsonc; dotcfg=1
    grep -qxF ".opencode/" "$(git rev-parse --git-path info/exclude)" || printf '.opencode/\n' >> "$(git rev-parse --git-path info/exclude)"
  fi

  info "▶ ${agent}（試行 ${attempt} / ${model}）  ログ: $out"
  t0=$(date +%s)
  # shellcheck disable=SC2086
  OPENCODE_CONFIG="$cfg" "$OPENCODE_BIN" run $OPENCODE_RUN_FLAGS --agent "$agent" "$prompt" >"$out" 2>"$errf" &
  pid=$!
  # Ctrl-C / 終了時に opencode も止める（バックグラウンドジョブは SIGINT を受け取らないため）
  trap 'kill -TERM "$pid" 2>/dev/null; st set status halted; st set halt_reason interrupted; progress; err "中断しました。再開: req2pr run $N --resume"; exit 130' INT TERM
  ( sleep "$AGENT_TIMEOUT"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" || rc=$?
  trap - INT TERM
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  if [ -n "$dotcfg" ]; then rm -f .opencode/opencode.jsonc; rmdir .opencode 2>/dev/null || true; fi

  hx usage record --work "$WORK" --agent "$agent" --attempt "$attempt" --model "$model" \
    --log "$out" --duration "$(( $(date +%s) - t0 ))" --exit-code "$rc" || warn "使用量の記録に失敗しました"
  hx usage summary --work "$WORK" > "$WORK/usage-summary.md" 2>/dev/null || true
  progress
  if [ "$rc" -ne 0 ]; then
    warn "$agent が終了コード $rc で終了しました（$errf を確認）"
    tail -n 5 "$errf" 2>/dev/null | sed 's/^/    /' >&2 || true
  fi
  return 0
}

# retry <agent> <上限> <ゲート関数> [追加の指示]
retry() {
  local agent="$1" max="$2" gate="$3" extra="${4:-}" i
  for i in $(seq 1 "$max"); do
    oc "$agent" "$extra"
    if $gate; then
      st gate "$gate" pass "$i"
      rm -f "$WORK/feedback.md"
      progress
      ok "$gate 合格（${agent} 試行 $i/$max）"
      return 0
    fi
    st gate "$gate" fail "$i" "$(head -c 400 "$WORK/feedback.md" 2>/dev/null | tr '\n' ' ')"
    progress
    warn "$gate 不合格（${agent} 試行 $i/$max）"
  done
  return 1
}

# ---------------------------------------------------------------- ゲート
write_feedback() {  # write_feedback <見出し> <本文ファイル or ->
  { printf '# フィードバック: %s\n\n' "$1"; cat; } > "$WORK/feedback.md"
}

# ① 設計ゲート
check_contract() {
  local outp
  if outp=$(hx gate "$WORK" contract 2>&1); then
    return 0
  fi
  printf '%s\n' "$outp" | write_feedback "contract.md / qa-cases.yaml の形式チェックで不合格"
  return 1
}

# ② Red ゲート: テスト以外が未変更 / 全 TC-ID がテストにある / テストが落ちる
check_red() {
  local changed tests others outp log="$WORK/logs/red.log"
  changed=$(changed_files)
  tests=$(printf '%s\n' "$changed" | hx match "$TEST_GLOBS")
  others=$(printf '%s\n' "$changed" | hx match "$TEST_GLOBS" --invert)
  {
    if [ -n "$others" ]; then
      printf -- '- テストファイル以外が変更されていたため元に戻しました（test-writer はテストだけを書きます）:\n'
      printf '%s\n' "$others" | sed 's/^/  - /'
    fi
  } > "$WORK/logs/red.others"
  if [ -n "$others" ]; then
    # shellcheck disable=SC2046
    revert_paths HEAD $(printf '%s\n' "$others")
  fi
  if ! outp=$(printf '%s\n' "$tests" | hx gate "$WORK" tc-ids 2>&1); then
    { cat "$WORK/logs/red.others"; printf '%s\n' "$outp"; } | write_feedback "Red ゲート不合格（テストが設計表と一致しません）"
    return 1
  fi
  if bash .req2pr/bin/test >"$log" 2>&1; then
    { cat "$WORK/logs/red.others"
      printf -- '- テストが「通って」しまいました。追加したテストが、まだ実装されていない振る舞いを検証しているか確認してください\n'
      printf '\n```\n'; tail -n 40 "$log"; printf '```\n'; } | write_feedback "Red ゲート不合格（テストが失敗しません）"
    return 1
  fi
  return 0
}

# ③ Green ゲート: テストロック / test / lint
check_green() {
  local ref locked tl ll
  ref=$(st get test_ref)
  locked=$( { git diff --name-only "$ref"; git ls-files --others --exclude-standard; } | sort -u | hx match "$TEST_GLOBS")
  if [ -n "$locked" ]; then
    # shellcheck disable=SC2046
    revert_paths "$ref" $(printf '%s\n' "$locked")
    { printf -- '- テストファイルが変更されていたため元に戻しました。テストは編集禁止です。実装側を修正してください:\n'
      printf '%s\n' "$locked" | sed 's/^/  - /'; } | write_feedback "Green ゲート不合格（テストロック違反）"
    return 1
  fi
  tl="$WORK/logs/green-test.log"; ll="$WORK/logs/green-lint.log"
  if ! bash .req2pr/bin/test >"$tl" 2>&1; then
    { printf -- '- テストが失敗しています（.req2pr/bin/test の出力末尾）:\n\n```\n'; tail -n 80 "$tl"; printf '```\n'; } \
      | write_feedback "Green ゲート不合格（テスト失敗）"
    return 1
  fi
  if ! bash .req2pr/bin/lint >"$ll" 2>&1; then
    { printf -- '- テストは通りましたが lint / 型チェックが失敗しています（.req2pr/bin/lint の出力末尾）:\n\n```\n'; tail -n 80 "$ll"; printf '```\n'; } \
      | write_feedback "Green ゲート不合格（lint 失敗）"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- 人の承認
approve() {
  local unresolved ans comment
  [ "${APPROVAL:-interactive}" = "skip" ] && { warn "APPROVAL=skip のため人の承認を省略します"; return 0; }
  [ -t 0 ] || die "承認には対話端末が必要です（評価用途なら APPROVAL=skip）"
  while true; do
    unresolved=$(hx gate "$WORK" contract 2>/dev/null | sed -n '/^UNRESOLVED$/,$p' | sed '1d' || true)
    printf '\n%s\n' "────────── 設計の確認（Issue #$N） ──────────" >&2
    printf '  contract : %s\n  QA項目   : %s\n' "$WORK/contract.md" "$WORK/qa/qa-cases.yaml" >&2
    if [ -n "$unresolved" ]; then
      printf '%s\n' "${C_YEL}  不明点があります:${C_RST}" >&2
      printf '%s\n' "$unresolved" | sed 's/^/    /' >&2
    fi
    printf '\n  [v] 表示  [y] 承認  [e] エディタで修正  [r] 修正依頼して再設計  [q] 中断\n  > ' >&2
    read -r ans
    case "$ans" in
      v|V) { printf '===== %s =====\n' "$WORK/contract.md"; cat "$WORK/contract.md"
             printf '\n===== %s =====\n' "$WORK/qa/qa-cases.yaml"; cat "$WORK/qa/qa-cases.yaml"; } | ${PAGER:-less} ;;
      y|Y) if check_contract; then st gate approve pass; rm -f "$WORK/feedback.md"; return 0; fi
           warn "形式チェックに不合格のため承認できません。e で修正するか r で再設計してください:"
           sed 's/^/    /' "$WORK/feedback.md" >&2 ;;
      e|E) ${EDITOR:-vi} "$WORK/contract.md" "$WORK/qa/qa-cases.yaml"
           check_contract || { warn "形式チェックで不合格:"; sed 's/^/    /' "$WORK/feedback.md" >&2; } ;;
      r|R) printf '  修正依頼を入力（空行で終了）:\n' >&2
           comment=""
           while IFS= read -r line; do [ -z "$line" ] && break; comment="$comment$line"$'\n'; done
           printf '%s' "$comment" | write_feedback "人からの修正依頼（contract / QA項目を見直してください）"
           st gate approve revise
           return 2 ;;
      q|Q) st gate approve rejected; return 1 ;;
    esac
  done
}

# ---------------------------------------------------------------- アプリ起動
APP_PID=""
start_app() {
  local url="${APP_HEALTH_URL:-$APP_URL}" i
  if [ "${APP_ALREADY_RUNNING:-0}" = "1" ]; then
    curl -sf -o /dev/null --max-time 5 "$url" && return 0
    err "APP_ALREADY_RUNNING=1 ですがアプリに接続できません: $url"
    return 1
  fi
  if curl -sf -o /dev/null --max-time 3 "$url" 2>/dev/null; then
    err "QA 開始前に $url が既に応答しています。起動中の開発サーバーを止めるか、APP_ALREADY_RUNNING=1 を指定してください"
    return 1
  fi
  info "アプリを起動します: $APP_START"
  ( exec bash -c "$APP_START" ) >"$WORK/logs/app.log" 2>&1 &
  APP_PID=$!
  for i in $(seq 1 "$APP_START_TIMEOUT"); do
    if curl -sf -o /dev/null --max-time 2 "$url" 2>/dev/null; then ok "アプリ起動を確認しました（${i}秒）"; return 0; fi
    kill -0 "$APP_PID" 2>/dev/null || { tail -n 20 "$WORK/logs/app.log" >&2; stop_app; return 1; }
    sleep 1
  done
  err "アプリが ${APP_START_TIMEOUT} 秒以内に応答しませんでした（$WORK/logs/app.log）"
  stop_app
  return 1
}

_kill_tree() {
  local pid="$1" c
  for c in $(pgrep -P "$pid" 2>/dev/null); do _kill_tree "$c"; done
  kill "$pid" 2>/dev/null || true
}

stop_app() {
  [ -n "$APP_PID" ] || return 0
  _kill_tree "$APP_PID"
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
}
