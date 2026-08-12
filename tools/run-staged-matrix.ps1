# 段階エントリーの比較を一括で回す。
#
# 決済方式3種類 × 段階エントリー3種類 × RSI閾値2種類 を、学習期間
# （2018/11〜2022/12）で通す。
#
# 段階エントリーが「使わない」のとき RSI は一切効かない（EA 側で
# RSI の読み取りごと飛ばしている）ため、RSI 違いの2通りは同じ結果に
# なる。重複を省いて 3×(1 + 2×2) = 15 通りを回す。
#
# 前提: MT5 を閉じておくこと（run-backtest.ps1 が起動中なら弾く）。
# 1本ずつ順に走らせる。並列にすると同じデータフォルダを奪い合う。

[CmdletBinding()]
param(
    [string]$From = '2018.11.01',
    [string]$To   = '2022.12.31',
    [string]$Period = 'M5',
    [string]$Suffix = '',       # 識別名の末尾（過去の実行と CSV がぶつからないように）
    [int]$TimeoutMin = 120
)

$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'run-backtest.ps1'

$exits  = @{ 0 = 'A'; 1 = 'B'; 2 = 'C' }
$combos = @()

foreach ($e in 0, 1, 2) {
    # 段階なしでは RSI の見送り条件が働かないので、閾値違いは同じ結果になる
    $combos += [pscustomobject]@{ Tag = "$($exits[$e])_off$Suffix"; Exit = $e; Staged = 0; Up = 80; Low = 20 }

    foreach ($s in 1, 2) {
        foreach ($r in @(@(80, 20), @(70, 30))) {
            $combos += [pscustomobject]@{
                Tag    = "$($exits[$e])_s$($s)_$($r[0])$($r[1])$Suffix"
                Exit   = $e
                Staged = $s
                Up     = $r[0]
                Low    = $r[1]
            }
        }
    }
}

Write-Host ("回す組み合わせ: {0} 通り" -f $combos.Count)
$combos | ForEach-Object { Write-Host ("  {0}" -f $_.Tag) }

$total = [System.Diagnostics.Stopwatch]::StartNew()
$failed = @()

for ($i = 0; $i -lt $combos.Count; $i++) {
    $c = $combos[$i]
    Write-Host ""
    Write-Host ("===== [{0}/{1}] {2} =====" -f ($i + 1), $combos.Count, $c.Tag)

    try {
        & $runner -Tag $c.Tag -From $From -To $To -Period $Period `
                  -Exit $c.Exit -StagedMode $c.Staged `
                  -RsiUpper $c.Up -RsiLower $c.Low -TimeoutMin $TimeoutMin
    }
    catch {
        # 1本失敗したら残りも同じ理由で失敗する。同じ警告を並べても何も
        # 分からないので、その場で止める
        Write-Warning ("{0} が失敗: {1}" -f $c.Tag, $_.Exception.Message)
        Write-Warning ("残り {0} 本は実行していません。" -f ($combos.Count - $i - 1))
        $failed += $c.Tag
        break
    }
}

$total.Stop()
Write-Host ""
Write-Host ("全体 {0:N1} 分" -f $total.Elapsed.TotalMinutes)
if ($failed.Count -gt 0) { Write-Warning ("失敗: " + ($failed -join ', ')) }
else { Write-Host "全て完了" }
