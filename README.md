# req2pr

GitHub の issue から、**設計 → テスト駆動の実装 → ブラウザ QA（スクショ付き Excel）→ Draft PR** までを自動で進めるハーネスです。設計は Claude、実装と QA はローカル LLM（LM Studio）が担当し、エージェントは [OpenCode](https://opencode.ai) で動かします。

```
req2pr run 12
 ├─ ① 設計（Claude）           完了要件・テスト設計・実装方針・QA項目 → 人が承認
 ├─ ② テスト作成（ローカル）     テストが失敗することを確認（Red）
 ├─ ③ 実装（ローカル）           テストは編集不可。test・lint が通るまで（Green）
 ├─ ④ QAシート作成               QA項目から Excel を作る
 ├─ ⑤ QA実施（ローカル＋ブラウザ） 操作・スクショ → Excel に記入。NG なら ③ へ
 └─ ⑥ Draft PR 作成
```

合否はテスト・lint の終了コードと QA 結果だけで判定します。上限回数に達したら中断して通知し、`--resume` で再開できます。

## 必要なもの

- macOS（Linux / WSL2 でも可）。ローカル LLM のためメモリ 32GB 以上推奨
- [Homebrew](https://brew.sh)（以下の手順で使用）
- git、curl、Python 3.9+、Node.js 18+、Google Chrome
- [GitHub CLI](https://cli.github.com)（`gh auth login` 済み、対象リポジトリに push できること）
- [LM Studio](https://lmstudio.ai)（アプリ版で可）と Qwen3-Coder-30B-A3B-Instruct
- [Anthropic API キー](https://console.anthropic.com)（従量課金）
- [OpenCode](https://opencode.ai) V2 の **CLI**（デスクトップアプリを使っていても CLI が必要）
- 対象リポジトリ：テストと lint をコマンドで実行でき、ローカルで起動できる Web アプリ

## セットアップ

### 1. ツールを入れる

```bash
brew install gh node anomalyco/tap/opencode-v2
gh auth login
opencode --version
```

`gh auth login` の途中の「Authenticate Git with your GitHub credentials?」は Yes を選びます。`opencode --version` が 2.x であることを確認してください。

Anthropic の API キーはシェルの環境変数で渡します（リポジトリや設定ファイルには書かない）。

```bash
echo 'export ANTHROPIC_API_KEY="（キー）"' >> ~/.zshrc
exec zsh
```

### 2. LM Studio を準備する

1. アプリを起動し、検索で **Qwen3-Coder-30B-A3B-Instruct**（Apple Silicon なら MLX 4bit 以上）をダウンロード
2. **Developer** タブでサーバーを **Running** にする
3. モデルを **Context Length 65536 以上**でロードする（既定値のままだと動きません）
4. モデル ID を確認する：`curl -s http://127.0.0.1:1234/v1/models` の `id`。既定の `qwen/qwen3-coder-30b` と違う場合は、手順 4 の `req2pr init` のあとに `~/.config/req2pr/local.env` へ `LOCAL_MODEL_ID="（id）"` と書く

ハーネスの実行中は LM Studio を起動したままにしてください。

### 3. ハーネスを入れる

```bash
git clone https://github.com/ktgwShota/req2pr.git ~/.req2pr
cd ~/.req2pr
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
mkdir -p ~/.local/bin && ln -sf ~/.req2pr/bin/req2pr ~/.local/bin/req2pr
```

`~/.local/bin` が PATH に入っていなければ追加し、`req2pr help` が動くことを確認します。

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
exec zsh
req2pr help
```

### 4. 対象リポジトリを登録する

```bash
cd ~/src/myapp
req2pr init
```

作られたファイルを編集します。どれも**あなたのマシンだけの設定**で、このリポジトリには入りません。

| ファイル（`~/.config/req2pr/` 配下） | 書くこと |
|---|---|
| `projects/<owner>__<repo>/project.env` | テスト・lint・起動のコマンド、URL、テストファイルのパターン（必須。行頭の `#` を外して書き換える） |
| `projects/<owner>__<repo>/project.md` | 構成・規約・QA 用のログイン情報など（サンプルは架空の内容なので全部書き換える）。全エージェントが毎回読むので短く |
| `local.env` | モデル ID などを既定値から変える場合だけ |

設定できる項目と既定値は [`config/defaults.sh`](config/defaults.sh) のコメントがリファレンスです。値は `defaults.sh` → `local.env` → `project.env` → 環境変数 の順に上書きされます。

### 5. 確認する

```bash
req2pr config
req2pr doctor
```

`req2pr config` は使われる設定値と出どころを、`req2pr doctor` は必要なツール・LM Studio・ブラウザ・設定を確認します。`✘` がなくなるまで対処してください。

## 使い方

対象リポジトリで、未コミットの変更がない状態で実行します。ハーネスは `req2pr/issue-<N>` ブランチを作って作業し、終了後もそのブランチのままになります。

| コマンド | 内容 |
|---|---|
| `req2pr run 12` | issue #12 を処理する |
| `req2pr status 12` | 進捗と使用量を表示する |
| `req2pr run 12 --resume` | 中断した工程から再開する |
| `req2pr reset 12` | 作業を破棄して最初からやり直せる状態に戻す（ブランチと作業ファイルを削除し、PR があれば閉じる） |
| `req2pr report --month 2026-11` | API 料金の月次集計 |

途中で設計の承認を求められます。`v` 表示／`y` 承認／`e` 直接編集（`$EDITOR`。未設定なら vi なので、例えば `export EDITOR=nano`）／`r` 修正依頼して作り直し／`q` 中断。**後の工程はすべてこの設計に従うので、ここが最も重要な確認ポイントです。** 承認した設計は issue にコメントされます（公開リポジトリでは公開されます。不要なら `project.env` に `POST_CONTRACT_COMMENT=0`）。

最初は小さく、完了条件がはっきりした issue で試してください。

| 成果物 | 場所 |
|---|---|
| Draft PR | 完了要件・QA 結果（スクショ付き）・料金の要約入り |
| QA シート・承認済み設計 | 対象リポジトリの `docs/qa/<N>/`（PR に含まれる） |
| 作業ファイル・ログ・進捗 | 対象リポジトリの `.req2pr/<N>/`（git 管理外） |
| 全プロジェクトの使用量台帳 | `~/.local/share/req2pr/usage-ledger.csv` |

中断したときは `req2pr status <N>` と `.req2pr/<N>/feedback.md`（直近の失敗内容）を見て、原因を直してから `--resume` してください。再開は止まった工程から行います（承認前なら承認画面から、QA で止まった場合はテストが通っていれば QA から）。最初からやり直す場合は `req2pr reset <N>` のあとに `req2pr run <N>` します。

### 初回の確認

最初の実行のあと、`.req2pr/<N>/logs/*.err` にエラーがないこと、`.req2pr/<N>/usage.jsonl` が `"usage_found": true` であることを確認してください。OpenCode のバージョン差で動かない場合は `local.env` で調整します。

- `opencode run` のオプションが合わない → `OPENCODE_RUN_FLAGS`
- エージェントが見つからない → `OPENCODE_CONFIG_MODE="dotdir"`

## 注意

- ハーネスのコミットは、対象リポジトリの pre-commit フックを実行しません（失敗するテストをコミットするため。`GIT_COMMIT_FLAGS` で変更可）
- このハーネス自体を改修する人へ：プロジェクト固有の値・API キーをコミットしないでください（`pip install pre-commit && pre-commit install` で gitleaks の検査が有効になります）
- 料金はローカルの `~/.config/req2pr/pricing.json`（[`config/pricing.json`](config/pricing.json) をコピーして単価を記入）で計算します。未記入なら OpenCode が計算した値を記録します

## ライセンス

MIT
