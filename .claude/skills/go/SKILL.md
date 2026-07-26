---
name: go
description: mql5-ea-lab専用のセッション開始チェック。RTK と context-mode のバージョン更新確認＋次タスク提示（tasks/TASK_MASTER.md 先頭の未完了タスク）。前回の作業継続は context-mode が自動注入するため扱わない。「おはよう」「作業開始」でも発火。
allowed-tools: Read, Glob, Grep, Bash, PowerShell, mcp__plugin_context-mode_context-mode__ctx_execute_file
---

# go（mql5-ea-lab セッション開始）

セッション開始時の環境メンテチェックと**次タスク提示**を行い、最後にサマリーを提示する。

**本スキルは mql5-ea-lab ローカル限定**。タスクファイルは必ずリポジトリ直下の `tasks/TASK_MASTER.md` を対象とする（Globで他リポジトリを探索しない＝誤って別プロジェクトのファイルを参照しないため）。

「前回情報」は2種類あり扱いが違う:
- **(A) どこまで作業したか（＝セッションのイベント）** … context-mode の SessionStart フックが自動注入済み。本スキルでは扱わない（深掘りは `ctx_search`）。
- **(B) ロードマップ上の次タスク（＝tasks/TASK_MASTER.md のチェックボックス状態）** … (A) とは別物。Step 3 で `ctx_execute_file` を使い、**全行を Read せず**先頭の未完了タスクだけを抽出する（毎セッション実行するため、生ファイル読込はコンテキスト・利用制限の無駄）。

> **【実行方法の必須注意】** 下記は `$()` 等のシジルを含むため、**必ず PowerShell ツールで直接実行**する。Bash 経由だと `$()` が展開されて壊れ、許可プロンプトも出る。各 Step は独立。エラーが出ても次へ進む。

---

## Step 1: RTK のバージョン確認

```powershell
$rtkCur = (rtk --version) -replace '[^\d.]',''
try {
  $rtkLatest = (Invoke-RestMethod "https://api.github.com/repos/rtk-ai/rtk/releases/latest").tag_name -replace '[^\d.]',''
  if ($rtkCur -ne $rtkLatest) { "RTK: 現行 $rtkCur / 最新 $rtkLatest [更新あり]" }
  else { "RTK: $rtkCur [最新]" }
} catch { "RTK: $rtkCur （GitHub 確認失敗）" }
```

更新がある場合はユーザーに通知し、**ユーザー確認後**に案内する（Windows のため原則 [Releases](https://github.com/rtk-ai/rtk/releases) から手動ダウンロード→展開→PATH 配置）。自動更新はしない。

---

## Step 2: context-mode のバージョン確認

```powershell
$cmInstalled = (Get-ChildItem "$env:USERPROFILE\.claude\plugins\cache\context-mode\context-mode" -Directory -ErrorAction SilentlyContinue |
  Sort-Object Name -Descending | Select-Object -First 1).Name
try {
  $cmLatest = (Invoke-RestMethod "https://registry.npmjs.org/context-mode/latest").version
  if ($cmInstalled -ne $cmLatest) { "context-mode: 現行 $cmInstalled / 最新 $cmLatest [更新あり]" }
  else { "context-mode: $cmInstalled [最新]" }
} catch { "context-mode: $cmInstalled （npm 確認失敗）" }
```

判定と対応:

- **更新あり**: ユーザーに通知する。**自動 update は絶対にしない**。context-mode は第三者製のため、**更新前に通信処理を再監査する運用**:
  1. 一時クローンで差分監査: `rtk git clone --depth 1 https://github.com/mksglu/context-mode /d/tmp/cm-audit-new`
  2. `hooks/platform-bridge.mjs` のクラウド転送が引き続きオプトイン（`~/.context-mode/platform.json` 必須・自動生成なし）か、新たな外部送信先(`fetch`/`POST`/新URL)が増えていないか、秘密情報の redact が維持されているかを確認
  3. 問題なければ `rtk claude plugin update context-mode@context-mode`（再起動で反映）
- **最新**: その旨をサマリーに記載。
- **導入版が取得できない**（`$cmInstalled` が空）: プラグイン未導入の可能性。サマリーに「context-mode: 未導入」と記載。

---

## Step 3: 次タスク提示

`tasks/TASK_MASTER.md`（**リポジトリ直下固定パス。Globで探索しない**）から先頭の未完了タスクを抽出する。**全行を Read せず** `ctx_execute_file` でサンドボックス内処理し、答え（次タスク＋後続数件）だけをコンテキストへ返す。

1. 対象パスは `tasks/TASK_MASTER.md`（リポジトリルート基準）固定。存在しない場合は「tasks/TASK_MASTER.md が見つかりません」と報告し、Step 4 へ進む。
2. `ctx_execute_file(path="tasks/TASK_MASTER.md", language="javascript", code=...)` を以下のコードで実行する:

```javascript
const lines = FILE_CONTENT.split('\n');
let phase = '';
const pending = [];
for (const line of lines) {
  const h = line.match(/^##\s+(.*)/);
  if (h) { phase = h[1].trim(); continue; }
  if (/^\s*-\s*\[ \]/.test(line) && !line.includes('~~')) {
    const task = line.replace(/^\s*-\s*\[ \]\s*/, '').replace(/\*\*/g, '').trim();
    pending.push({ phase, task });
  }
}
if (pending.length === 0) {
  console.log('未完了タスクなし（全完了）');
} else {
  const first = pending[0];
  console.log('▶ 次の推奨タスク');
  console.log(`  [${first.phase}]`);
  console.log(`  ${first.task}`);
  console.log(`\n後続の未完了（全${pending.length}件）:`);
  for (const p of pending.slice(1, 4)) console.log(`  - ${p.task}`);
}
```

出力の先頭1件をサマリーの「次タスク」に載せる。tasks/TASK_MASTER.md が見つからない／空の場合はその旨を記載し次へ進む。

---

## Step 4: サマリー提示

```
## セッション開始チェック結果（mql5-ea-lab）

### バージョン更新
- RTK: 現行 X.Y.Z / 最新 A.B.C  [更新あり / 最新]
- context-mode: 現行 X.Y.Z / 最新 A.B.C  [更新あり / 最新 / 未導入]

### 次タスク（tasks/TASK_MASTER.md）
- ▶ #N: ...（[Phase X]）
- 後続: #M, ...

### 前回の継続
- context-mode が自動注入済み（深掘りは ctx_search）

### アップデート提案
（更新があるもののみ列挙し、実行可否をユーザーに確認。context-mode は再監査を経てから update）
```

---

## 注意事項

- **本スキルは mql5-ea-lab ローカル限定**。他プロジェクト（例: OLS-MeanReversion_MT5）のファイルには一切触れない。
- タスクファイルは `tasks/TASK_MASTER.md` 固定パスのみを参照する（Globで他リポジトリのTASK_MASTER.mdを誤って拾わない）。
- アップデート実行は**必ずユーザー確認後**。自動実行しない。
- **context-mode の更新は通信処理の再監査を経てから**（第三者製・サプライチェーン対策）。
- バージョン取得 API が失敗した場合はその旨を報告し、手動確認を促す。
- 全て日本語で記述する。
