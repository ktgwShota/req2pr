# shellcheck shell=bash
# req2pr の汎用既定値（公開リポジトリ）。
# プロジェクト固有の値はここに書かず、$REQ2PR_CONFIG 側の project.env / local.env に書く。

# ---- モデル -------------------------------------------------------------
LMSTUDIO_BASE_URL="http://127.0.0.1:1234/v1"
LOCAL_MODEL_ID="qwen/qwen3-coder-30b"          # LM Studio 上のモデル ID（`lms ls` / GET /v1/models で確認）
LOCAL_CONTEXT_LENGTH=65536                     # lms load 時のコンテキスト長
PLANNER_MODEL="anthropic/claude-opus-5-5"      # ① 設計
REVIEWER_MODEL="anthropic/claude-sonnet-5-5"   # ⑤' QAレビュー（QA_REVIEW=1 のときだけ使用）

# ---- 工程の上限回数 -----------------------------------------------------
MAX_RED=3          # ② test-writer の試行上限
MAX_GREEN=3        # ③ implementer の試行上限（QA 1周あたり）
MAX_QA=2           # ③〜⑤ の周回上限（--resume 時はリセット）
MAX_PLAN=3         # ① planner の形式チェック不合格時の再試行上限
# 1回の実行でエージェントが使えるステップ数の上限（必要なら上書き）
# STEPS_PLANNER=80 STEPS_TEST_WRITER=60 STEPS_IMPLEMENTER=120 STEPS_QA_RUNNER=200 STEPS_QA_REVIEWER=60

# ---- 動作 ---------------------------------------------------------------
BASE_BRANCH=""                  # 空ならリモートの既定ブランチを使う
BRANCH_PREFIX="req2pr/issue-"
COMMIT_TYPE="feat"              # PR 用コミットの種別（feat / fix など）
GIT_COMMIT_FLAGS="--no-verify"  # ハーネスのコミットで対象リポジトリの pre-commit フックを動かさない（失敗するテストをコミットするため）。空にするとフックを実行
QA_DOCS_DIR="docs/qa"           # PR に含める QA 成果物の置き場所（<QA_DOCS_DIR>/<N>/）
QA_REVIEW=0                     # 1 で qa-reviewer（Claude・画像）を有効化
APPROVAL="interactive"          # interactive | skip（評価用。人の承認を省略）
POST_CONTRACT_COMMENT=1         # 承認した contract を issue にコメントする（0 で無効。公開リポジトリでは内容が公開される）
APP_START_TIMEOUT=120           # アプリ起動待ちの秒数
APP_HEALTH_URL=""               # 空なら APP_URL でヘルスチェック
APP_ALREADY_RUNNING=0           # 1 ならハーネスはアプリを起動・停止しない
NOTIFY_CMD=""                   # 通知コマンド。メッセージが第1引数で渡る（空なら macOS 通知 / 標準出力）
AGENT_TIMEOUT=3600              # 1回のエージェント実行の制限時間（秒）

# ---- QA（Playwright MCP） -----------------------------------------------
PLAYWRIGHT_BROWSER="chrome"     # chrome | msedge | firefox | webkit（chrome / msedge はインストール済みのブラウザを使う）
PLAYWRIGHT_MCP_PACKAGE="@playwright/mcp@latest"

# ---- OpenCode -----------------------------------------------------------
OPENCODE_BIN="opencode"
OPENCODE_RUN_FLAGS="--standalone --format json"   # opencode run に渡すオプション
OPENCODE_CONFIG_MODE="env"      # env: OPENCODE_CONFIG で渡す / dotdir: 対象リポジトリの .opencode/ に一時配置
