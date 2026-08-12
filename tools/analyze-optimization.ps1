# 最適化（多数パス）の CSV をまとめて解析する。
#
# EA は1パスごとに r1_<Tag>_summary_NNN.csv と r1_<Tag>_trades_NNN.csv を
# 共有フォルダへ書く。連番はパスの実行順ではないので、条件の識別は
# summary に書かれたパラメータで行う。
#
# 整合性の確認も同時に行う: 最適化では複数のエージェントが並行して走り、
# 空き連番を選ぶ処理が競合しうる。summary の trades 件数と trades CSV の
# 行数がずれていたら、別パスの結果を突き合わせている可能性がある。

[CmdletBinding()]
param(
    [string]$Tag = 'smoke',
    [int]$MinTrades = 50,        # これ未満はサンプル不足として別扱い
    [int]$Top = 25,
    [string]$Common = (Join-Path $env:APPDATA 'MetaQuotes\Terminal\Common\Files')
)

$ErrorActionPreference = 'Stop'

$rows = @()
$mismatch = 0

foreach ($f in Get-ChildItem $Common -Filter "r1_${Tag}_summary*.csv") {
    $seq = if ($f.Name -match '_summary_(\d+)\.csv$') { "_$($Matches[1])" } else { '' }
    $tp = Join-Path $Common "r1_${Tag}_trades$seq.csv"
    if (-not (Test-Path $tp)) { continue }

    $s = @{}
    Import-Csv $f.FullName -Header 'k', 'v' | Select-Object -Skip 1 | ForEach-Object { $s[$_.k] = $_.v }

    $point = [double]$s['point']
    $pip = if ([int]$s['digits'] -in 3, 5) { $point * 10 } else { $point }

    $gross = @(); $net = @(); $held = @()
    foreach ($t in Import-Csv $tp) {
        $cp = [double]$t.close_price
        if ($cp -eq 0) { continue }
        $n = [int]$t.dir * ($cp - [double]$t.open_price) / $pip
        $net += $n
        $gross += ($n + (([double]$t.open_spread_pt + [double]$t.close_spread_pt) / 2.0) * $point / $pip)
        $held += [int]$t.bars_held
    }
    if ($gross.Count -eq 0) { continue }

    # summary が数えた取引数と、明細の行数（決済価格が取れた分）の差
    if ([int]$s['trades'] -lt $gross.Count) { $mismatch++ }

    $m = $gross | Measure-Object -Average -StandardDeviation
    $se = if ($gross.Count -gt 1) { $m.StandardDeviation / [math]::Sqrt($gross.Count) } else { 0 }
    $wins = @($gross | Where-Object { $_ -gt 0 }).Count

    # exit_name は ANSI（Shift-JIS）で書かれており読むと化けるので番号を使う
    $rows += [pscustomobject]@{
        足     = ($s['period'] -replace '^PERIOD_', '')
        決済   = @('A', 'B', 'C')[[int]$s['exit_method']]
        段階   = $s['staged_mode']
        R決済  = $s['use_rsi_exit']
        上限   = [double]$s['rsi_upper']
        下限   = [double]$s['rsi_lower']
        装填本 = $s['arm_bars']
        期間   = $s['period_bars']
        遅行   = $s['lag_bars']
        σ倍   = [double]$s['sigma_mult']
        取引   = $gross.Count
        グロス = [math]::Round($m.Average, 2)
        ネット = [math]::Round(($net | Measure-Object -Average).Average, 2)
        誤差   = [math]::Round($se, 2)
        上側95 = [math]::Round($m.Average + 1.96 * $se, 2)
        勝率   = [math]::Round(100.0 * $wins / $gross.Count, 1)
        保有   = [math]::Round(($held | Measure-Object -Average).Average, 1)
    }
}

Write-Host ("パス数: {0}" -f $rows.Count)
Write-Host ("時間足: " + (($rows | Group-Object 足 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '))
Write-Host ("取引 {0} 件以上: {1} パス" -f $MinTrades, @($rows | Where-Object { $_.取引 -ge $MinTrades }).Count)
if ($mismatch -gt 0) { Write-Warning "summary と明細の件数が合わないパスが $mismatch 件（並行実行で連番が競合した可能性）" }

# どのパラメータが実際に振られたか。振っていない軸は最適化の意味がない
Write-Host ""
Write-Host "=== 振られた値の分布 ==="
foreach ($col in '決済', '段階', 'R決済', '上限', '下限', '装填本', '期間', '遅行', 'σ倍') {
    $g = $rows | Group-Object $col | Sort-Object Name
    Write-Host ("{0,-6}: {1}" -f $col, (($g | ForEach-Object { "$($_.Name)($($_.Count))" }) -join ' '))
}

$ok = $rows | Where-Object { $_.取引 -ge $MinTrades }

Write-Host ""
Write-Host ("=== 平均グロス上位 {0}（取引 {1} 件以上） ===" -f $Top, $MinTrades)
$ok | Sort-Object グロス -Descending | Select-Object -First $Top `
    決済, 段階, R決済, 上限, 下限, 取引, グロス, ネット, 誤差, 上側95, 勝率, 保有 | Format-Table -AutoSize

# 同じ挙動のパスが重複していないかを見る。段階も RSI決済も切ってあると
# RSI の閾値は一切効かないため、閾値だけ違うパスは全て同じ結果になる
Write-Host "=== 決済方式 × RSI決済 ごとの最良 ==="
$ok | Group-Object 決済, R決済 | ForEach-Object {
    $b = $_.Group | Sort-Object グロス -Descending | Select-Object -First 1
    [pscustomobject]@{
        決済 = $b.決済; R決済 = $b.R決済; パス数 = $_.Count
        異なる結果 = @($_.Group | Select-Object -ExpandProperty グロス -Unique).Count
        上限 = $b.上限; 下限 = $b.下限; 取引 = $b.取引
        グロス = $b.グロス; ネット = $b.ネット; 誤差 = $b.誤差; 上側95 = $b.上側95
    }
} | Sort-Object グロス -Descending | Format-Table -AutoSize

Write-Host "合否ラインは平均グロス 3.7 pips（往復コスト 1.22 × 3）。docs/backtest_design.md"
