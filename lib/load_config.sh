# shellcheck shell=bash
# 設定の読み込み。下ほど優先:
#   1. $REQ2PR_HOME/config/defaults.sh                    公開リポジトリの汎用既定値
#   2. $REQ2PR_CONFIG/local.env                           マシン共通（非公開）
#   3. $REQ2PR_CONFIG/projects/<owner>__<repo>/project.env プロジェクト別（非公開）
#   4. --env-file <path>                                   一時的な設定ファイル
#   5. 環境変数                                            その場で上書き
# bash 3.2（macOS 標準）でも動くように書いている。

REQ2PR_KEYS="LMSTUDIO_BASE_URL LOCAL_MODEL_ID LOCAL_CONTEXT_LENGTH PLANNER_MODEL REVIEWER_MODEL
MAX_RED MAX_GREEN MAX_QA MAX_PLAN BASE_BRANCH BRANCH_PREFIX COMMIT_TYPE GIT_COMMIT_FLAGS QA_DOCS_DIR QA_REVIEW APPROVAL
POST_CONTRACT_COMMENT APP_START_TIMEOUT APP_HEALTH_URL APP_ALREADY_RUNNING NOTIFY_CMD AGENT_TIMEOUT
OPENCODE_BIN OPENCODE_RUN_FLAGS OPENCODE_CONFIG_MODE PLAYWRIGHT_MCP_PACKAGE PLAYWRIGHT_BROWSER
STEPS_PLANNER STEPS_TEST_WRITER STEPS_IMPLEMENTER STEPS_QA_RUNNER STEPS_QA_REVIEWER
TEST_CMD LINT_CMD APP_START APP_URL TEST_GLOBS"

REQ2PR_REQUIRED="TEST_CMD LINT_CMD APP_START APP_URL TEST_GLOBS"

# 設定ファイルを読む（存在しなければ何もしない）
_hx_source() {
  local f="$1"
  [ -f "$f" ] || return 0
  # shellcheck disable=SC1090
  set -a; . "$f"; set +a
  REQ2PR_CONFIG_FILES="${REQ2PR_CONFIG_FILES:-} $f"
}

# load_config <repo_id> [env_file]
load_config() {
  local repo_id="$1" env_file="${2:-}" k snap=""
  export PROJECT_DIR="$REQ2PR_CONFIG/projects/$repo_id"
  export REQ2PR_PROJECT_MD="$PROJECT_DIR/project.md"
  REQ2PR_CONFIG_FILES=""

  # 5. 環境変数で渡された値を退避（ファイルで上書きされないように）
  for k in $REQ2PR_KEYS; do
    if eval "[ -n \"\${$k+x}\" ]"; then
      snap="$snap $k"
      eval "__HXENV_$k=\"\${$k}\""
    fi
  done

  _hx_source "$REQ2PR_HOME/config/defaults.sh"
  _hx_source "$REQ2PR_CONFIG/local.env"
  _hx_source "$PROJECT_DIR/project.env"
  if [ -n "$env_file" ]; then
    [ -f "$env_file" ] || die "--env-file が見つかりません: $env_file"
    _hx_source "$env_file"
  fi

  for k in $snap; do
    eval "$k=\"\${__HXENV_$k}\""
  done
  REQ2PR_ENV_OVERRIDES="$snap"

  # 既定値の補完（defaults.sh に無いもの）
  : "${MAX_PLAN:=3}"
  : "${AGENT_TIMEOUT:=3600}"
  : "${OPENCODE_BIN:=opencode}"
  : "${OPENCODE_RUN_FLAGS:=--standalone --format json}"
  : "${OPENCODE_CONFIG_MODE:=env}"
  : "${PLAYWRIGHT_MCP_PACKAGE:=@playwright/mcp@latest}"
  : "${PLAYWRIGHT_BROWSER:=chrome}"
  : "${GIT_COMMIT_FLAGS=--no-verify}"
  : "${STEPS_PLANNER:=80}" "${STEPS_TEST_WRITER:=60}" "${STEPS_IMPLEMENTER:=120}" "${STEPS_QA_RUNNER:=200}" "${STEPS_QA_REVIEWER:=60}"

  for k in $REQ2PR_KEYS; do
    eval "export $k"
  done
}

# 必須値の検証
validate_config() {
  local k missing=""
  for k in $REQ2PR_REQUIRED; do
    eval "[ -n \"\${$k:-}\" ]" || missing="$missing $k"
  done
  if [ -n "$missing" ]; then
    err "必須の設定が未設定です:$missing"
    err "  $PROJECT_DIR/project.env に書くか、環境変数で渡してください（req2pr init で雛形を作成できます）"
    return 1
  fi
}

# 設定値の出どころ（req2pr config 用）
config_origin() {
  local k="$1" f origin="(未設定)"
  for f in $REQ2PR_CONFIG_FILES; do
    if grep -Eq "^[[:space:]]*(export[[:space:]]+)?$k=" "$f" 2>/dev/null; then
      origin="$f"
    fi
  done
  case " $REQ2PR_ENV_OVERRIDES " in *" $k "*) origin="環境変数" ;; esac
  if [ "$origin" = "(未設定)" ] && eval "[ -n \"\${$k:-}\" ]"; then origin="(組み込み既定値)"; fi
  printf '%s' "$origin"
}
