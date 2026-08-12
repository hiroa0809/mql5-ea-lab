# ①膠着の「本数」を振って、この条件が何を測っているのかを確かめる。
#
# ①膠着は「直前 N 本のあいだ遅行スパンが ±3σ の内側にとどまっていた」。
# ±3σ の外に出ることは③突破そのものなので、実質は「直前 N 本のあいだ
# 3σ抜けが起きていない」＝連続発火を抑える冷却期間として働く。
#
# N を変えても成績が動かなければ、①はこのロジックにとって効いていない軸
# だと分かる。切った場合（UseSqueeze=0）も並べて比べる。
#
# 決済方式は C（3方式で最良）、段階エントリーは使わない設定に固定する。
# ②遅行線は 2026-08-12 に削除済み。
#
# 前提: MT5 を閉じておくこと。1本ずつ順に走らせる。

[CmdletBinding()]
param(
    [string]$From = '2018.11.01',
    [string]$To   = '2022.12.31',
    [string[]]$Periods = @('M5', 'M15'),
    [int[]]$SqueezeBars = @(5, 10, 21, 31, 42, 63),
    [int[]]$ExpandBars  = @(3, 8),
    [int]$TimeoutMin = 120
)

$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'run-backtest.ps1'

$combos = @()
foreach ($p in $Periods) {
    $tf = $p.ToLower()
    foreach ($eb in $ExpandBars) {
        # ①を切った場合。本数は効かないので既定値のまま渡す
        $combos += [pscustomobject]@{
            Tag = "q_off_e${eb}_$tf"; Period = $p; Use = 0; SB = 21; EB = $eb
        }
        foreach ($sb in $SqueezeBars) {
            $combos += [pscustomobject]@{
                Tag = ("q{0:d2}_e{1}_{2}" -f $sb, $eb, $tf); Period = $p; Use = 1; SB = $sb; EB = $eb
            }
        }
    }
}

Write-Host ("回す組み合わせ: {0} 通り" -f $combos.Count)

$total = [System.Diagnostics.Stopwatch]::StartNew()
$failed = @()

for ($i = 0; $i -lt $combos.Count; $i++) {
    $c = $combos[$i]
    Write-Host ""
    Write-Host ("===== [{0}/{1}] {2} =====" -f ($i + 1), $combos.Count, $c.Tag)
    try {
        & $runner -Tag $c.Tag -From $From -To $To -Period $c.Period `
                  -Exit 2 -UseSqueeze $c.Use -SqueezeBars $c.SB -ExpandBars $c.EB `
                  -StagedMode 0 -TimeoutMin $TimeoutMin
    }
    catch {
        # 1本失敗したら残りも同じ理由で失敗する。28本ぶん同じ警告を並べても
        # 何も分からないので、その場で止める
        Write-Warning ("{0} が失敗: {1}" -f $c.Tag, $_.Exception.Message)
        Write-Warning ("残り {0} 本は実行していません。原因を直してから回し直してください。" -f ($combos.Count - $i - 1))
        $failed += $c.Tag
        break
    }
}

$total.Stop()
Write-Host ""
Write-Host ("全体 {0:N1} 分" -f $total.Elapsed.TotalMinutes)
if ($failed.Count -gt 0) { Write-Warning ("失敗: " + ($failed -join ', ')) }
else { Write-Host "全て完了" }
