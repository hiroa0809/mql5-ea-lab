# パラボリック SAR の決済を、学習期間（2018/11〜2022/12）で比較する。
#
# 固定する条件は N6-1b の最良設定（tasks/TASK_MASTER.md）:
#   15分足・決済方式C（遅行スパンが反対側へ陰転）・①膠着21本・④拡大8本
#   段階エントリーは使わない。②遅行線はコードから削除済み
# この設定で 933取引・平均グロス 1.93 pips が出ている。**これを動かさない**。
# 動かすと、成績の変化が SAR のせいなのか設定変更のせいなのか分離できない。
#
# 前提: MT5 を閉じておくこと（run-backtest.ps1 が起動中なら弾く）。
#
# ティックの再現方式（Model）の使い分け:
#   sar_off_m2 … 2（始値のみ）。**既存の 1.93 pips を再現するための回帰確認**。
#                 SAR を使わないので始値のみで過不足なく、数分で終わる
#   それ以外    … 4（実際のティックに基づく全ティック）。**必須**。
#                 2 では OnTick が足に1回しか来ないため Bid 判定が
#                 「足の始値で1回」に退化し、スプレッド拡大も再現されない。
#                 その2点こそが2つの執行方式の勝敗を分ける対象なので、
#                 4 以外で回した結果は比較に使えない
#
# 実ティックは遅い。1本あたり数十分かかることがある。-Only で絞れる。

[CmdletBinding()]
param(
    [string]$From = '2018.11.01',
    [string]$To   = '2022.12.31',
    [string]$Symbol = 'USDJPY#',
    [string]$Period = 'M15',
    [string]$Suffix = '',          # 識別名の末尾（過去の実行と CSV がぶつからないように）
    [string[]]$Only = @(),         # 指定した識別名だけ回す（空なら全部）
    [int]$TimeoutMin = 240
)

$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'run-backtest.ps1'

# N6-1b の最良設定。ここを変えるなら TASK_MASTER の記述も直すこと
$base = @{
    Symbol      = $Symbol
    Period      = $Period
    From        = $From
    To          = $To
    Exit        = 2      # C: 遅行スパンが反対側へ陰転
    SqueezeBars = 21
    ExpandBars  = 8
    StagedMode  = 0
    TimeoutMin  = $TimeoutMin
}

$runs = @(
    # 回帰確認。SAR を使わず、既存の 1.93 pips が再現されるかを見る
    [pscustomobject]@{ Tag = 'sar_off_m2'   ; SarMode = 0; SarExec = 0; Gate = 0; Model = 2 }
    # 以下は比較用。ベースラインも同じティック方式で取り直す
    [pscustomobject]@{ Tag = 'sar_off'      ; SarMode = 0; SarExec = 0; Gate = 0; Model = 4 }
    [pscustomobject]@{ Tag = 'sar_only_stop'; SarMode = 1; SarExec = 0; Gate = 0; Model = 4 }
    [pscustomobject]@{ Tag = 'sar_only_bid' ; SarMode = 1; SarExec = 1; Gate = 0; Model = 4 }
    [pscustomobject]@{ Tag = 'sar_both_stop'; SarMode = 2; SarExec = 0; Gate = 0; Model = 4 }
    [pscustomobject]@{ Tag = 'sar_both_bid' ; SarMode = 2; SarExec = 1; Gate = 0; Model = 4 }
    # ゲート ON。sar_only_stop と完全一致すれば「ポインタが逆側」は一度も
    # 起きなかったことの証明になる
    [pscustomobject]@{ Tag = 'sar_gate_stop'; SarMode = 1; SarExec = 0; Gate = 1; Model = 4 }
)

if ($Only.Count -gt 0) {
    $runs = @($runs | Where-Object { $Only -contains $_.Tag })
    if ($runs.Count -eq 0) { Write-Error "-Only に一致する識別名がありません: $($Only -join ', ')" }
}

Write-Host ("回す本数: {0}" -f $runs.Count)
$runs | ForEach-Object { Write-Host ("  {0}  (SAR={1}/{2} ゲート={3} ティック={4})" -f $_.Tag, $_.SarMode, $_.SarExec, $_.Gate, $_.Model) }

$total  = [System.Diagnostics.Stopwatch]::StartNew()
$failed = @()

foreach ($r in $runs) {
    $tag = "$($r.Tag)$Suffix"
    Write-Host ""
    Write-Host ("=== {0} ===" -f $tag)

    try {
        & $runner @base -Tag $tag -SarMode $r.SarMode -SarExec $r.SarExec -SarEntryGate $r.Gate -Model $r.Model
    }
    catch {
        Write-Warning ("{0} が失敗しました: {1}" -f $tag, $_.Exception.Message)
        $failed += $tag
    }
}

$total.Stop()
Write-Host ""
Write-Host ("全体 {0:N1} 分" -f $total.Elapsed.TotalMinutes)

if ($failed.Count -gt 0) {
    Write-Warning ("失敗: {0}" -f ($failed -join ', '))
    exit 1
}
