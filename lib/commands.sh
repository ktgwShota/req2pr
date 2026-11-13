# shellcheck shell=bash
# req2pr init / config / doctor / status / report

_in_repo() {
  ROOT=$(repo_root) || die "対象リポジトリ（git）の中で実行してください"
  cd "$ROOT"
  detect_repo
}

cmd_init() {
  _in_repo
  local dir="$REQ2PR_CONFIG/projects/$REPO_ID"
  mkdir -p "$dir" "$REQ2PR_DATA"
  chmod 700 "$REQ2PR_CONFIG" 2>/dev/null || true
  if [ -f "$dir/project.env" ]; then
    info "既に存在します: $dir/project.env"
  else
    cp "$REQ2PR_HOME/examples/project.env.example" "$dir/project.env"
    ok "作成しました: $dir/project.env"
  fi
  if [ ! -f "$dir/project.md" ]; then
    cp "$REQ2PR_HOME/examples/project.md.example" "$dir/project.md"
    ok "作成しました: $dir/project.md"
  fi
  if [ ! -f "$REQ2PR_CONFIG/local.env" ]; then
    cp "$REQ2PR_HOME/examples/local.env.example" "$REQ2PR_CONFIG/local.env"
    ok "作成しました: $REQ2PR_CONFIG/local.env"
  fi
  cat >&2 <<EOF

次の手順:
  1. $dir/project.env にテスト・lint・起動コマンドなどを書く
  2. $dir/project.md にプロジェクトの構成・規約・注意点を書く（全エージェントが読みます）
  3. req2pr config で設定値を確認、req2pr doctor で環境を確認
  4. req2pr run <issue番号>
EOF
}

cmd_config() {
  local env_file="" k v
  case "${1:-}" in --env-file) env_file="${2:-}" ;; --env-file=*) env_file="${1#*=}" ;; esac
  if [ -n "$env_file" ]; then
    [ -f "$env_file" ] || die "--env-file が見つかりません: $env_file"
    env_file="$(cd "$(dirname "$env_file")" && pwd)/$(basename "$env_file")"
  fi
  _in_repo
  load_config "$REPO_ID" "$env_file"
  printf 'リポジトリ: %s\nプロジェクト設定: %s\n\n' "$REPO" "$PROJECT_DIR" >&2
  for k in $REQ2PR_KEYS; do
    eval "v=\${$k:-}"
    printf '%-24s %-48s %s\n' "$k" "${v:-}" "$(config_origin "$k")"
  done
  printf '\n' >&2
  validate_config && ok "必須の設定はそろっています"
}

_check() {  # _check <ラベル> <コマンド...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else err "$label"; DOCTOR_FAIL=1; fi
}

cmd_doctor() {
  DOCTOR_FAIL=0
  local help ver nodev in_repo=0
  if ROOT=$(repo_root); then
    in_repo=1; cd "$ROOT"; detect_repo
  else
    REPO_ID="__none__"
  fi
  load_config "$REPO_ID" ""

  info "── ツール"
  _check "git" command -v git
  _check "curl" command -v curl
  _check "gh（GitHub CLI）" command -v gh
  _check "gh の認証（gh auth login）" gh auth status
  if command -v node >/dev/null 2>&1; then
    nodev=$(node -v | sed 's/^v//; s/\..*//')
    if [ "${nodev:-0}" -ge 18 ]; then ok "Node.js $(node -v)"; else err "Node.js 18 以上が必要です（現在 $(node -v)）"; DOCTOR_FAIL=1; fi
  else
    err "Node.js が見つかりません（Playwright MCP の起動に必要）"; DOCTOR_FAIL=1
  fi
  _check "npx" command -v npx
  _check "Python 依存（pyyaml / openpyxl / pillow）: $PY" "$PY" -I -c "import yaml, openpyxl, PIL"

  info "── OpenCode"
  if command -v "$OPENCODE_BIN" >/dev/null 2>&1; then
    ver=$("$OPENCODE_BIN" --version 2>/dev/null | head -1 || true)
    ok "opencode ${ver}"
    case "$ver" in 0.*|1.*) warn "OpenCode V2 を前提にしています（現在 ${ver}）。README のインストール手順で V2 を入れてください" ;; esac
    help=$("$OPENCODE_BIN" run --help 2>&1 || true)
    for flag in $OPENCODE_RUN_FLAGS --agent; do
      case "$flag" in --*) ;; *) continue ;; esac
      if printf '%s' "$help" | grep -q -- "$flag"; then ok "opencode run $flag"
      else warn "opencode run のヘルプに $flag が見つかりません（OPENCODE_RUN_FLAGS を調整してください）"; fi
    done
  else
    if ls -d /Applications/OpenCode*.app >/dev/null 2>&1; then
      err "opencode コマンドが見つかりません。デスクトップアプリとは別に CLI が必要です（brew install anomalyco/tap/opencode-v2）"
    else
      err "opencode が見つかりません（README のセットアップ手順 1 でインストール）"
    fi
    DOCTOR_FAIL=1
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then ok "ANTHROPIC_API_KEY が設定されています"
  else warn "ANTHROPIC_API_KEY が未設定です（OpenCode に /connect で Anthropic を登録済みなら問題ありません）"; fi

  info "── LM Studio"
  if command -v lms >/dev/null 2>&1; then ok "lms CLI"; else warn "lms が見つかりません（LM Studio アプリを一度起動してください。サーバーの自動起動・モデルの自動ロードに使用）"; fi
  if curl -sf --max-time 5 "$LMSTUDIO_BASE_URL/models" >/dev/null 2>&1; then
    ok "LM Studio サーバー: $LMSTUDIO_BASE_URL"
    if command -v lms >/dev/null 2>&1 && lms ps 2>/dev/null | grep -qF "$LOCAL_MODEL_ID"; then
      ok "モデル $LOCAL_MODEL_ID がロードされています（Context Length が ${LOCAL_CONTEXT_LENGTH} 以上か LM Studio で確認してください）"
    elif curl -sf --max-time 5 "$LMSTUDIO_BASE_URL/models" | grep -qF "\"$LOCAL_MODEL_ID\""; then
      warn "モデル $LOCAL_MODEL_ID は見つかりましたが、ロード済みか確認できません（実行時に lms でロードを試みます）"
    else
      warn "モデル $LOCAL_MODEL_ID が見つかりません。curl -s $LMSTUDIO_BASE_URL/models の id を ~/.config/req2pr/local.env の LOCAL_MODEL_ID に書いてください"
    fi
  else
    warn "LM Studio サーバーに接続できません: $LMSTUDIO_BASE_URL（アプリの Developer タブでサーバーを Running に。実行時に lms server start も試みます）"
  fi

  info "── ブラウザ（Playwright MCP）"
  case "$PLAYWRIGHT_BROWSER" in
    chrome)
      if [ -d "/Applications/Google Chrome.app" ] || command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
        ok "Google Chrome"
      else
        err "Google Chrome が見つかりません（インストールするか PLAYWRIGHT_BROWSER を変更）"; DOCTOR_FAIL=1
      fi ;;
    msedge) ok "Microsoft Edge を使用（インストール済みであること）" ;;
    *) info "PLAYWRIGHT_BROWSER=$PLAYWRIGHT_BROWSER（未導入なら: npx playwright install $PLAYWRIGHT_BROWSER）" ;;
  esac

  info "── 単価表"
  local pricing="$REQ2PR_CONFIG/pricing.json"
  [ -f "$pricing" ] || pricing="$REQ2PR_HOME/config/pricing.json"
  if grep -q '"input": 0, "output": 0' "$pricing"; then
    warn "単価表（$pricing）が 0 のままです（その間は OpenCode が計算した料金を記録します）"
  else
    ok "単価表: $pricing"
  fi

  info "── プロジェクト設定"
  if [ "$in_repo" = 1 ]; then
    info "対象リポジトリ: $REPO"
    if [ -f "$PROJECT_DIR/project.env" ]; then ok "project.env: $PROJECT_DIR/project.env"
    else err "project.env がありません（req2pr init）"; DOCTOR_FAIL=1; fi
    if [ ! -f "$PROJECT_DIR/project.md" ]; then
      warn "project.md がありません（エージェントへのプロジェクト知識なし）"
    elif cmp -s "$PROJECT_DIR/project.md" "$REQ2PR_HOME/examples/project.md.example"; then
      err "project.md がサンプルのままです（架空の内容がエージェントに渡されます）: $PROJECT_DIR/project.md"; DOCTOR_FAIL=1
    else
      ok "project.md"
    fi
    validate_config || DOCTOR_FAIL=1
  else
    info "対象リポジトリの外で実行したため省略しました（対象リポジトリのディレクトリで再実行してください）"
  fi

  if [ "$DOCTOR_FAIL" = 0 ]; then ok "doctor: 必須項目に問題はありません（! の警告は内容を確認してください）"
  else err "doctor: 解決が必要な問題があります（✘ の項目）"; return 1; fi
}

# req2pr reset <N> [-y]: issue の作業を破棄して最初からやり直せる状態に戻す
cmd_reset() {
  local n="${1:-}" yes="${2:-}" branch base cur ans
  case "$n" in ''|*[!0-9]*) die "使い方: req2pr reset <issue番号> [-y]" ;; esac
  _in_repo
  load_config "$REPO_ID" ""
  branch="${BRANCH_PREFIX}${n}"
  base=""
  [ -f ".req2pr/$n/state.json" ] && base=$(hx state ".req2pr/$n" get base 2>/dev/null || true)
  [ -n "$base" ] || base=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  [ -n "$base" ] || base=main
  cur=$(git rev-parse --abbrev-ref HEAD)

  printf '%s\n' "Issue #$n の作業を破棄します:" >&2
  [ "$cur" = "$branch" ] && printf '  - %s の未コミットの変更を破棄し、%s に切り替える\n' "$branch" "$base" >&2
  git rev-parse --verify -q "refs/heads/$branch" >/dev/null && printf '  - ローカルブランチ %s を削除\n' "$branch" >&2
  printf '  - リモートに %s や PR があれば、PR を閉じてブランチを削除\n' "$branch" >&2
  printf '  - .req2pr/%s を削除\n' "$n" >&2
  if [ "$yes" != "-y" ]; then
    printf '続けますか？ [y/N] ' >&2; read -r ans || ans=""
    case "$ans" in y|Y) ;; *) info "中止しました"; return 1 ;; esac
  fi

  if [ "$cur" = "$branch" ]; then
    git reset -q --hard
    git clean -fdq          # .req2pr/ は exclude 済みなので消えない
    git switch -q "$base" 2>/dev/null || git switch -q -c "$base" "origin/$base"
  fi
  if git rev-parse --verify -q "refs/heads/$branch" >/dev/null; then git branch -q -D "$branch"; fi
  if gh pr view "$branch" --repo "$REPO" --json state -q .state 2>/dev/null | grep -q OPEN; then
    gh pr close "$branch" --repo "$REPO" --delete-branch >/dev/null 2>&1 && info "PR を閉じてリモートブランチを削除しました"
  elif git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git push -q origin --delete "$branch" && info "リモートブランチ $branch を削除しました"
  fi
  rm -rf ".req2pr/$n"
  ok "リセットしました。最初からやり直す: req2pr run $n"
}

cmd_status() {
  local n="${1:-}"
  _in_repo
  if [ -z "$n" ]; then
    if ! ls -1 .req2pr 2>/dev/null | grep -qE '^[0-9]+$'; then info "作業中の issue はありません"; return 0; fi
    ls -1 .req2pr | grep -E '^[0-9]+$' | while read -r i; do
      printf '#%-6s %s\n' "$i" "$(hx state ".req2pr/$i" get phase 2>/dev/null)/$(hx state ".req2pr/$i" get status 2>/dev/null)"
    done
    return 0
  fi
  [ -f ".req2pr/$n/progress.md" ] || die "Issue #$n の作業はありません"
  cat ".req2pr/$n/progress.md"
  [ -f ".req2pr/$n/usage-summary.md" ] && { printf '\n'; cat ".req2pr/$n/usage-summary.md"; }
  return 0
}
