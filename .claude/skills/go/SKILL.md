---
name: go
description: mql5-ea-lab専用のセッション開始チェック。RTK と context-mode のバージョン更新確認＋前回の続きの掘り起こし＋次タスク提示（tasks/TASK_MASTER.md）。「おはよう」「作業開始」でも発火。
allowed-tools: Read, Glob, Grep, Bash, PowerShell, mcp__plugin_context-mode_context-mode__ctx_execute_file, mcp__plugin_context-mode_context-mode__ctx_search
---

# go（mql5-ea-lab セッション開始）

環境 → 前回の続き → 次タスク の順に確認し、最後にサマリーを出す。各 Step は独立で、エラーが出ても次へ進む。タスクファイルは `tasks/TASK_MASTER.md` 固定（Glob で探索しない＝他プロジェクトの同名ファイルを誤参照しないため）。他プロジェクトのファイルには触れない。

> PowerShell のコードは `$()` を含むため**必ず PowerShell ツールで実行**する。Bash 経由では壊れ、許可プロンプトも出る。

---

## Step 1: バージョン確認

```powershell
$rtkCur = (rtk --version) -replace '[^\d.]',''
try {
  $rtkLatest = (Invoke-RestMethod "https://api.github.com/repos/rtk-ai/rtk/releases/latest").tag_name -replace '[^\d.]',''
  if ($rtkCur -ne $rtkLatest) { "RTK: 現行 $rtkCur / 最新 $rtkLatest [更新あり]" } else { "RTK: $rtkCur [最新]" }
} catch { "RTK: $rtkCur （GitHub 確認失敗）" }
```

```powershell
$cmInstalled = (Get-ChildItem "$env:USERPROFILE\.claude\plugins\cache\context-mode\context-mode" -Directory -ErrorAction SilentlyContinue |
  Sort-Object Name -Descending | Select-Object -First 1).Name
try {
  $cmLatest = (Invoke-RestMethod "https://registry.npmjs.org/context-mode/latest").version
  if ($cmInstalled -ne $cmLatest) { "context-mode: 現行 $cmInstalled / 最新 $cmLatest [更新あり]" } else { "context-mode: $cmInstalled [最新]" }
} catch { "context-mode: $cmInstalled （npm 確認失敗）" }
```

更新があれば**通知のみ。実行は必ずユーザー確認後**。RTK は [Releases](https://github.com/rtk-ai/rtk/releases) から手動で入れ替える。取得失敗はその旨を報告。`$cmInstalled` が空なら「未導入」。

context-mode は第三者製のため**更新前に通信処理を再監査する**。一時クローン（`rtk git clone --depth 1 https://github.com/mksglu/context-mode /d/tmp/cm-audit-new`）の `hooks/platform-bridge.mjs` で、クラウド送信がオプトインのまま（`~/.context-mode/platform.json` 必須・自動生成なし）か、送信先が増えていないか、秘密情報の伏せ字が残っているかを確認 → `rtk claude plugin update context-mode@context-mode`。

---

## Step 2: 前回の続き

**前回の作業内容は自動では入ってこない。** context-mode が差し込むのは「再開」と「自動要約」のときだけで、新規開始では差し込まない（`hooks/sessionstart.mjs` の startup 分岐。同ファイルのコメントは実装と食い違うので信じない）。記録は残っているので**並列で**取りに行く。

1. `rtk git log --oneline -5`
2. `rtk gh pr list --repo hiroa0809/mql5-ea-lab --state open --json number,title,headRefName,updatedAt`
   開いた PR があれば `rtk proxy gh pr checks <PR#> --repo hiroa0809/mql5-ea-lab` でレビュー状況を見る。**判定は右端の説明文**（`state` は `SUCCESS` でも `Review skipped` なら未レビュー）
3. `ctx_search(queries: [...], sort: "timeline", limit: 5)` — 質問は**1回の呼び出しにまとめる**（回数制限あり）。Step 3 のタスク名を質問に混ぜると当たりやすい

検索は設計書の中身が上位に来て「出来事」が取れないことがある。**取れなければ「取れなかった」と書く。** 食い違ったらコミットと PR を優先する。

---

## Step 3: 次タスク

**進捗（着手済み・保留・PR 未マージ）はチェックボックスの行ではなく、その下にぶら下がった箇条書きに書かれる。** チェックボックスは決定待ち等で未完了のまま据え置かれるため、行だけ見て「未着手」と判断しない。

`ctx_execute_file(path="tasks/TASK_MASTER.md", language="javascript", code=…)` で抽出する（全行 Read はしない）。ファイルが無ければその旨を報告して Step 4 へ。

```javascript
const lines = FILE_CONTENT.split('\n');
const cap = (s, n) => (s.length > n ? s.slice(0, n) + ' …' : s);
let phase = '';
const pending = [];

for (let i = 0; i < lines.length; i++) {
  const h = lines[i].match(/^##\s+(.*)/);
  if (h) { phase = h[1].trim(); continue; }
  const m = lines[i].match(/^(\s*)-\s*\[ \]/);
  if (!m || lines[i].includes('~~')) continue;
  const indent = m[1].length;

  // ぶら下がり行（見出し、または同じ深さ以下の箇条書きで終わり）
  const notes = [];
  for (let j = i + 1; j < lines.length; j++) {
    if (/^#{1,6}\s/.test(lines[j])) break;
    const nm = lines[j].match(/^(\s*)-\s/);
    if (nm && nm[1].length <= indent) break;
    if (lines[j].trim()) notes.push(lines[j].replace(/\*\*/g, '').trim());
  }
  // 「確定事実」は着手時に読む資料。行数だけ数える。見出しは箇条書きでない点で見分ける
  // （本文中の「下の確定事実を参照」で切ると進捗行を巻き添えにする）
  const cut = notes.findIndex(n => !n.startsWith('- ') && /確定事実/.test(n));
  pending.push({
    phase,
    task: lines[i].replace(/^\s*-\s*\[ \]\s*/, '').replace(/\*\*/g, '').trim(),
    head: cut >= 0 ? notes.slice(0, cut) : notes,
    facts: cut >= 0 ? notes.length - cut : 0,
  });
}

if (pending.length === 0) { console.log('未完了タスクなし（全完了）'); }
else {
  const f = pending[0];
  console.log(`▶ 先頭の未完了タスク\n  [${f.phase}]\n  ${f.task}`);
  if (f.head.length) {
    console.log('\n  ぶら下がっている注記（必ず読む）:');
    for (const n of f.head.slice(0, 12)) console.log(`    ${cap(n, 300)}`);
    if (f.head.length > 12) console.log(`    …（残り ${f.head.length - 12} 行）`);
  }
  if (f.facts) console.log(`  ※ 確定事実ブロックが ${f.facts} 行ある（着手時に読む）`);

  console.log(`\n後続の未完了（全${pending.length}件）:`);
  for (const p of pending.slice(1, 4)) {
    console.log(`  - ${p.task}`);
    const st = p.head.filter(n => !/^-?\s*完了条件/.test(n)
      && /実施済|完了|保留|見送り|未マージ|着手|残っている|進行/.test(n));
    for (const n of st.slice(0, 2)) console.log(`      ↳ ${cap(n, 300)}`);
  }
}
```

先頭タスクの注記に「保留」「次に着手するのは別のタスク」等があれば、**そちらを次タスクとして案内する**。注記を読まずに先頭1件を機械的に「次タスク」と書かない。

---

## Step 4: サマリー

見出し4つで出す。**バージョン更新**（2件。更新があるものは実行可否をユーザーに確認）／**前回の続き**（直近コミット・開いた PR とそのレビュー状況・記録から拾えたこと）／**次タスク**（先頭1件＋後続。着手済みなら「実装は完了・残りは○○」と注記を反映）／**アップデート提案**（更新があるときだけ）。

**確かめていないことを書かない。** 取れなかったものは「取れなかった」と書く。全て日本語。
