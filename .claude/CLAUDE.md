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

### 自動レビューは走らない（2026-08-16 PR #15 で判明・仕様変更）

**PR を作っても、push しても、CodeRabbit は自動でレビューしない。** スター10個未満のリポジトリは手動起動が必要という方針に変わった（本リポジトリは 0 個・公開設定）。

- チェックは `SUCCESS` / **`Review skipped: manual review required for this OSS repository`** のまま止まる。**`state` が `SUCCESS` なので、`description` を読まないと「合格」と誤読する。**
- 起動は `rtk gh pr comment <PR#> --repo hiroa0809/mql5-ea-lab --body "@coderabbitai review"`。
- スターを10個集める方向は追わない。手動起動はコマンド1つで済む。

### レビュー回数の制限

**1時間あたり1回**（ウォークスルーに `Your plan includes up to 1 review per rolling hour; N remain` と出る）。

- **短時間に何度も push して再レビューを走らせない**。複数の指摘は**まとめて1回の push** で対応する。
- 上限に達した場合は時間を置いてから `@coderabbitai review` を投稿する。

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

### PR の説明文を上書きされる（2026-08-19 PR #17 で発生）

**CodeRabbit はレビュー時に PR 本文を自分の「Summary by CodeRabbit」ブロックだけに置き換えることがある。** 追記ではなく丸ごと差し替えで、こちらが書いた概要・変更点・検証欄が消える。

- 後から PR 本文を編集するときは、**`gh pr view --json body` で現状を取ってから確認する**。前に書いた内容が残っている前提で追記すると、消えたことに気づかない。
- 復元するときは、自動生成ブロック（`<!-- ... release notes by coderabbit.ai -->` で挟まれた範囲）を末尾に残したまま、自前の説明をその前に置く。
- **消えて困る情報を PR 本文だけに置かない。** 検証の実施・未実施は `docs/` かコミットメッセージにも残す。

## MQL5 ビルド（コンパイル検証）

**`.claude/rules/mql5-build.md` に移した**（2026-08-08）。`.mq5` / `.mqh` を扱うときだけ読み込まれる設定（`paths` 指定）にしてある。

コンパイル手順・ジャンクション構成・「走らせていないのに検証済みと書かない」のルールはすべてそちらにある。**MQL5 のファイルを触るのに手順が見えていなければ、そのファイルを直接読むこと。**
