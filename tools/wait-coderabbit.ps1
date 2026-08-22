# CodeRabbit のレビュー完了を待つ。
#
# **state だけで判定しない。** レート制限のとき state は SUCCESS のまま
# description が "Review rate limited" になる。PENDING（Review in progress）
# から rate limited へ落ちることも実際に起きた（2026-08-08 PR #10）。
# state だけを見ると、1行もレビューされていないのに「指摘ゼロで通過」と
# 報告してしまう。
#
# 使い方（必ずバックグラウンドで起動する。この環境は前景の sleep が止まる）:
#   tools/wait-coderabbit.ps1 -Pr 20
#
# 終了コード
#   0 = レビュー完了（または FAILURE。どちらも指摘の取得へ進む）
#   2 = レート制限。レビューは走っていない。時間を置いて再起動する
#   3 = 自動レビュー未起動（スター10個未満のため）。手動起動が要る
#   4 = 時間切れ

[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Pr,
    [string]$Repo         = 'hiroa0809/mql5-ea-lab',
    [int]$IntervalSec     = 150,   # CodeRabbit は通常数分で終わる
    [int]$TimeoutMin      = 30
)

$ErrorActionPreference = 'Stop'
$deadline = (Get-Date).AddMinutes($TimeoutMin)

while ($true) {
    # チェックがまだ生成されていないと空になる。その間は回り続ける。
    $d = ''
    try {
        $d = (gh pr checks $Pr --repo $Repo --json name,state,description `
                --jq '.[] | select(.name=="CodeRabbit") | .state + " / " + .description') -join ''
    } catch { $d = '' }

    $stamp = (Get-Date).ToString('HH:mm:ss')
    Write-Host "$stamp  CodeRabbit: $(if ($d) { $d } else { '（チェック未生成）' })"

    if ($d -match 'Review completed') { Write-Host '完了。指摘の取得へ進む。'; exit 0 }
    if ($d -match '^FAILURE')         { Write-Host '失敗で確定。指摘の取得へ進む。'; exit 0 }
    if ($d -match 'rate limited')     { Write-Host 'レート制限。レビューは走っていない。時間を置いて @coderabbitai review を再投稿する。'; exit 2 }
    if ($d -match 'skipped')          { Write-Host '自動レビューが走っていない。@coderabbitai review で手動起動する。'; exit 3 }

    if ((Get-Date) -gt $deadline) {
        Write-Host "$TimeoutMin 分待っても完了しませんでした。PR の画面を確認してください。"
        exit 4
    }
    Start-Sleep -Seconds $IntervalSec
}
