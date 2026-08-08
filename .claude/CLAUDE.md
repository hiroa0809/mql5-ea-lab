# mql5-ea-lab プロジェクト指示

## Git運用ルール

- **`.mq5` / `.mqh` を含む変更**: featureブランチ → PR → CodeRabbitレビュー → マージ。main への直接 push はしない。
- **それ以外（`docs/` `tasks/` `.claude/` `.gitignore` 等）**: main で直接作業してよい（PR不要）。コミット前に `git status` で `.mq5`/`.mqh` の混入がないか確認する。混入していたらブランチへ退避（`git switch -c` は未コミット変更を持ち越す）。
- 手順の詳細は `/commit-pr`（PR作成）、`/fin`（セッションクローズ・ブランチ統合）が持つ。

### CodeRabbit の MQL5 対応（2026-07-26 PR #1 で検証済み）

**MQL5 に対応している。** 汎用レビューにとどまらず、MQL5 固有の仕様に踏み込んだ指摘ができる。

- PR #1 での実績: 4件の指摘のうち Major 2件が**実バグ**（`PositionClose(_Symbol)` のヘッジ口座での誤決済、取引要求の結果コード未確認）。いずれも `CTrade` / `SeriesInfoInteger` の公式ドキュメントを参照した上での指摘だった。
- 指摘・要約とも日本語で返る。
- 誤検知も出る（PR #1 では1件）。ただし MQL5 仕様の誤解ではなく、変数の初期値を見落とした状態追跡ミスだった。**実コード照合のトリアージは必須**。

### レビュー回数の制限（無料プラン）

無料プランには一定時間あたりのレビュー回数上限がある。上限に達すると `Review limit reached` が返り、次のレビューまで待たされる（PR #1 では約25分待ちが発生）。

- **短時間に何度も push して再レビューを走らせない**。複数の指摘は**まとめて1回の push** で対応する。
- 制限中に再レビューしたい場合は、時間を置いてから PR に `@coderabbitai review` とコメントする（新規 push でも起動する）。
- 従量課金（$0.25/ファイル）を有効にすれば即時レビューできるが、通常は待てばよい。

#### `@coderabbitai review` が効く条件（2026-07-31 PR #4 で確定）

「このコマンドは新規指摘ゼロになる」は**条件付き**。bot の注記どおり **`This command is applicable only when automatic reviews are paused.`**（自動レビューが停止している場合にのみ有効）であり、実際の挙動は状況で分かれる。

| 状況 | `@coderabbitai review` の結果 |
|---|---|
| コミットが既にレビュー済み | **新規指摘ゼロ**。増分方式のため再レビューしない（2026-07-26 PR #2） |
| **レート制限で自動レビューが走らなかった** | **実際にレビューされる**（2026-07-31 PR #4 で確認） |

- レート制限が解除されても、**制限中に来た push は遡って自動レビューされない**。手動起動が必須。
- 待ち時間は制限コメントに `Next review available in: N minutes` と明記される。**この N はコメントの投稿時刻が起点**（`created_at` ではなく `updated_at` を見る。ウォークスルーのコメントが更新される形で通知されるため）。
- 起動後の完了判定は `gh pr checks` の **`description`** を読む（`state` だけでは判定できない）。`SUCCESS` / `Review completed` が完了、`SUCCESS` / **`Review rate limited` はレビューが走っていない**。**`PENDING`（Review in progress）から `Review rate limited` へ落ちることもある**（2026-08-08 PR #10）。`state` だけを見ると、1行もレビューされていないのに「指摘ゼロで通過」と報告してしまう。
- **実際にレビューされたかの裏取り**は、ウォークスルーの `Reviewing files that changed ... between <old_sha> and <new_sha>` と `Files selected for processing (N)` を読む。応答が `Action performed / Review finished` だけでは、増分スキップと区別できない。

## MQL5 ビルド（コンパイル検証）

**`.claude/rules/mql5-build.md` に移した**（2026-08-08）。`.mq5` / `.mqh` を扱うときだけ読み込まれる設定（`paths` 指定）にしてある。

コンパイル手順・ジャンクション構成・「走らせていないのに検証済みと書かない」のルールはすべてそちらにある。**MQL5 のファイルを触るのに手順が見えていなければ、そのファイルを直接読むこと。**
