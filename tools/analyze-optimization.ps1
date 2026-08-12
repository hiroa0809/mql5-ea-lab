# 最適化（多数パス）の CSV をまとめて解析する。
#
# EA は1パスごとに r1_<Tag>_summary_NNN.csv と r1_<Tag>_trades_NNN.csv を
# 共有フォルダへ書く。連番はパスの実行順ではないので、条件の識別は
# summary に書かれたパラメータで行う。
#
# **売買結果を変える入力は全部 1 行に持つ。** 一部しか持たないと、条件の
# 違うパスが同じ表示行にまとまり、最良だった設定を再現できなくなる。
#
# 整合性の確認も同時に行う: 最適化では複数のエージェントが並行して走り、
# 空き連番を選ぶ処理が競合しうる。summary の取引数と trades CSV の行数が
# ずれていたら、別パスの結果を突き合わせている可能性がある。
# 比較の相手は**明細の全行数**にする。集計に使う行数（決済価格が取れた分）
# と比べると、テスト終了時に建玉が残った正常な実行まで警告してしまう。

[CmdletBinding()]
param(
    [string]$Tag = 'smoke',
    [int]$MinTrades = 50,        # これ未満はサンプル不足として除外
    [int]$Top = 20,
    [string]$Common = (Join-Path $env:APPDATA 'MetaQuotes\Terminal\Common\Files')
)

$ErrorActionPreference = 'Stop'

function Val($h, $k) { if ($h.ContainsKey($k) -and $h[$k] -ne '') { $h[$k] } else { '-' } }

$rows = @()
$mismatch = 0

foreach ($f in Get-ChildItem $Common -Filter "r1_${Tag}_summary*.csv" -ErrorAction SilentlyContinue) {
    if ($f.Name -notmatch '^r1_(?<tag>.+?)_summary(?<seq>_\d+)?\.csv$') { continue }
    $tradesPath = Join-Path $Common ("r1_{0}_trades{1}.csv" -f $Matches['tag'], $Matches['seq'])
    if (-not (Test-Path $tradesPath)) { continue }

    $s = @{}
    Import-Csv $f.FullName -Header 'k', 'v' | Select-Object -Skip 1 | ForEach-Object { $s[$_.k] = $_.v }

    $point = [double]$s['point']
    $pip = if ([int]$s['digits'] -in 3, 5) { $point * 10 } else { $point }

    $all = @(Import-Csv $tradesPath)
    $gross = @(); $net = @(); $held = @()
    foreach ($t in $all) {
        $cp = [double]$t.close_price
        if ($cp -eq 0) { continue }   # 決済価格を取れていない行は集計から外す
        $n = [int]$t.dir * ($cp - [double]$t.open_price) / $pip
        $net += $n
        $gross += ($n + (([double]$t.open_spread_pt + [double]$t.close_spread_pt) / 2.0) * $point / $pip)
        $held += [int]$t.bars_held
    }

    # 突き合わせ違いの検出。全行数と比べるので、決済価格が取れない行が
    # あっても誤検知しない
    if ([int]$s['trades'] -ne $all.Count) { $mismatch++ }
    if ($gross.Count -eq 0) { continue }

    $m = $gross | Measure-Object -Average -StandardDeviation
    $se = if ($gross.Count -gt 1) { $m.StandardDeviation / [math]::Sqrt($gross.Count) } else { 0 }
    $wins = @($gross | Where-Object { $_ -gt 0 }).Count

    # exit_name は ANSI（Shift-JIS）で書かれており読むと化けるので番号を使う
    $rows += [pscustomobject]@{
        "足"     = ((Val $s 'period') -replace '^PERIOD_', '')
        "決済"   = @('A', 'B', 'C')[[int]$s['exit_method']]
        "段階"   = Val $s 'staged_mode'
        "膠着"   = Val $s 'use_squeeze'
        "膠着本" = Val $s 'squeeze_bars'
        "拡大"   = Val $s 'use_expand'
        "拡大本" = Val $s 'expand_bars'
        "期間"   = Val $s 'period_bars'
        "遅行"   = Val $s 'lag_bars'
        "σ倍"   = Val $s 'sigma_mult'
        "損切"   = Val $s 'use_sl'
        "損切σ" = Val $s 'sl_sigma'
        "時間切" = Val $s 'use_timestop'
        "保有本" = Val $s 'hold_bars'
        "ドテン" = Val $s 'reverse'
        "装填本" = Val $s 'arm_bars'
        "RSI期"  = Val $s 'rsi_period'
        "上限"   = Val $s 'rsi_upper'
        "下限"   = Val $s 'rsi_lower'
        "取引"   = $gross.Count
        "グロス" = [math]::Round($m.Average, 2)
        "ネット" = [math]::Round(($net | Measure-Object -Average).Average, 2)
        "誤差"   = [math]::Round($se, 2)
        "上側95" = [math]::Round($m.Average + 1.96 * $se, 2)
        "勝率"   = [math]::Round(100.0 * $wins / $gross.Count, 1)
        "保有"   = [math]::Round(($held | Measure-Object -Average).Average, 1)
    }
}

if ($rows.Count -eq 0) { Write-Warning "識別名 $Tag の CSV が見つかりません"; return }

$params = '足', '決済', '段階', '膠着', '膠着本', '拡大', '拡大本', '期間', '遅行', 'σ倍',
          '損切', '損切σ', '時間切', '保有本', 'ドテン', '装填本', 'RSI期', '上限', '下限'

Write-Host ("パス数: {0}   取引 {1} 件以上: {2}" -f
            $rows.Count, $MinTrades, @($rows | Where-Object { $_.取引 -ge $MinTrades }).Count)
if ($mismatch -gt 0) { Write-Warning "summary の取引数と明細の行数が合わないパスが $mismatch 件（並行実行で連番が競合した可能性）" }

Write-Host ""
Write-Host "=== 振られた値の分布（値が1種類の軸は振られていない） ==="
foreach ($col in $params) {
    $g = $rows | Group-Object $col | Sort-Object Name
    Write-Host ("{0,-7}: {1}" -f $col, (($g | ForEach-Object { "$($_.Name)($($_.Count))" }) -join ' '))
}

$ok = $rows | Where-Object { $_.取引 -ge $MinTrades } | Sort-Object グロス -Descending
if (-not $ok) { Write-Warning "取引 $MinTrades 件以上のパスがありません"; return }

Write-Host ""
Write-Host ("=== 平均グロス上位 {0} ===" -f $Top)
$ok | Select-Object -First $Top 足, 決済, 段階, 膠着本, 拡大本, 上限, 下限, 取引, グロス, ネット, 誤差, 上側95, 勝率 |
    Format-Table -AutoSize

Write-Host "=== 最良パスの全設定（再現用） ==="
$ok | Select-Object -First 1 | Format-List

Write-Host "合否ラインは平均グロス 3.7 pips（往復コスト 1.22 × 3）。docs/backtest_design.md"
