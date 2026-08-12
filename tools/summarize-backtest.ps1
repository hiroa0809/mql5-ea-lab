# バックテストの CSV から、判定に使う数字だけを表にする。
#
# テスターの標準レポートは口座通貨での純損益しか出さない。判定に使うのは
# スプレッドを除いたグロス損益なので、EA が書いた trades CSV から計算する。
#
# グロス = ネット + 往復コスト。往復コストは建玉時と決済時のスプレッドの
# 平均とする（買いは Ask で建てて Bid で決済するため、仲値から見た負担は
# 両端のスプレッドの半分ずつになる）。
#
# 使い方: .\tools\summarize-backtest.ps1 -Pattern 'A_*','B_*','C_*'

[CmdletBinding()]
param(
    [string[]]$Pattern = @('*'),
    [string]$Common = (Join-Path $env:APPDATA 'MetaQuotes\Terminal\Common\Files')
)

$ErrorActionPreference = 'Stop'

function Read-Summary([string]$path) {
    $h = @{}
    Import-Csv $path -Header 'key', 'value' | Select-Object -Skip 1 |
        ForEach-Object { $h[$_.key] = $_.value }
    return $h
}

$rows = @()

foreach ($pat in $Pattern) {
    # EA は同じ識別名で再実行すると _001 のような連番を付ける。連番なしだけを
    # 読むと、回し直しても古い結果を見続けることになる。summary と trades は
    # **同じ連番どうしで組にする**
    foreach ($f in Get-ChildItem $Common -Filter "r1_${pat}_summary*.csv" -ErrorAction SilentlyContinue) {
        if ($f.Name -notmatch '^r1_(?<tag>.+?)_summary(?<seq>_\d+)?\.csv$') { continue }
        $tag = $Matches['tag'] + $Matches['seq']
        $tradesPath = Join-Path $Common ("r1_{0}_trades{1}.csv" -f $Matches['tag'], $Matches['seq'])
        if (-not (Test-Path $tradesPath)) { continue }

        $s = Read-Summary $f.FullName
        $point = [double]$s['point']
        # 3桁・5桁表示の口座は 1 pip = 10 point
        $pip = if ([int]$s['digits'] -in 3, 5) { $point * 10 } else { $point }

        $gross = @(); $net = @(); $held = @()
        foreach ($t in Import-Csv $tradesPath) {
            $cp = [double]$t.close_price
            if ($cp -eq 0) { continue }   # 決済価格を取れていない行は除外
            $dir = [int]$t.dir
            $n = $dir * ($cp - [double]$t.open_price) / $pip
            $cost = (([double]$t.open_spread_pt + [double]$t.close_spread_pt) / 2.0) * $point / $pip
            $net += $n
            $gross += ($n + $cost)
            $held += [int]$t.bars_held
        }

        if ($gross.Count -eq 0) {
            $rows += [pscustomobject]@{
                Tag = $tag; 取引 = 0; 平均グロス = $null; 平均ネット = $null; 勝率 = $null
                保有 = $null; 装填1 = $s['armed1']; 装填2 = $s['armed2']; 発火 = $s['fired']
                見送り = $s['rsi_blocked']; 期限切れ = $s['arm_expired']
            }
            continue
        }

        $wins = @($gross | Where-Object { $_ -gt 0 }).Count
        $rows += [pscustomobject]@{
            Tag        = $tag
            取引       = $gross.Count
            平均グロス = [math]::Round(($gross | Measure-Object -Average).Average, 2)
            平均ネット = [math]::Round(($net   | Measure-Object -Average).Average, 2)
            勝率       = [math]::Round(100.0 * $wins / $gross.Count, 1)
            保有       = [math]::Round(($held | Measure-Object -Average).Average, 1)
            装填1      = $s['armed1']
            装填2      = $s['armed2']
            発火       = $s['fired']
            見送り     = $s['rsi_blocked']
            期限切れ   = $s['arm_expired']
        }
    }
}

$rows | Sort-Object Tag | Format-Table -AutoSize
Write-Host ""
Write-Host "合否ラインは平均グロス 3.7 pips（往復コスト 1.22 × 3）。docs/backtest_design.md"
