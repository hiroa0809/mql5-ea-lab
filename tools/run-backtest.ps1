# MT5 のストラテジーテスターを設定ファイル経由で自動実行する。
#
# **未実行**（2026-08-20）。打ち切った売買プログラムを起動する形だったものを
# 現在の EaSpanModel 向けに書き直したが、まだ一度も走らせていない。P3 の総当た
# りは MT5 の画面から手で回している（docs/backtest_plan_p3_squeeze.md）。
# 初めて使うときは、単発テスト1本で結果を突き合わせてから連続実行に使うこと。
#
# MT5 は /config:<ini> を渡すと、テストまたは総当たりを回して自分で終了する。
# これで人手を介さずに条件を変えた連続実行ができる。
#
# 前提: MT5 を閉じておくこと。同じデータフォルダを2つの端末が同時に使えない
# ため、起動中だと新しい設定が無視されて既存のウィンドウが前面に出るだけに
# なる。走らせたつもりで何も起きない状態になるので、ここで弾く。
#
# **売買結果を変える入力は全部 [TesterInputs] に書く。** 書かなかった入力は
# ソースの初期値ではなく、**テスターが前回使った値**を引き継ぐ。手で最適化を
# 回した後などに前の設定が残り、気づかないまま別条件で走る（2026-08-12 に
# 発生）。そのため本スクリプトは、全項目に既定値を持たせて必ず書き出す。
#
# **設定ファイルは UTF-16 で書く。** UTF-8 だと MT5 はエラーも出さずに無視し、
# 端末が普通に起動するだけで終わる。
#
# 振り方の書き方（各パラメータ）:
#   -LagMode 5            固定
#   -SqueezeUse 1:1:5     1 から 5 まで 1 刻みで振る（開始:刻み:終了）
#
# 総当たりの結果は -Report で指定した XML に出る。単発テストでは使わない。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Tag,                  # 実行の識別名。設定・レポートの名前になる
    [Parameter(Mandatory)][string]$Period,               # M5 / M10 / M15 / H1
    [string]$From   = '2018.11.01',                      # 学習期間の開始
    [string]$To     = '2022.12.31',                      # 学習期間の終了
    [string]$Symbol = 'USDJPY#',

    # 2=始値のみ。本 EA は足の始値でしか売買しないため過不足ない。
    # **実行モデルは必ず結果と一緒に控える。** 2026-08-19 の総当たりは
    # 控え忘れており、5分足の 1取引 0.16 pips がモデル依存かを確かめられない。
    [int]$Model = 2,

    [switch]$Optimize,                                   # 総当たりにする
    [string]$Report = '',                                # 総当たりの結果 XML（絶対パス）

    # スパンモデル側
    [string]$Tenkan       = '9',
    [string]$Kijun        = '26',
    [string]$SpanB        = '52',
    [string]$LagBars      = '26',
    [string]$LagMode      = '5',                         # ②遅行スパン 0=なし 1=a終値 2=b高値安値 3=c雲 4=a+c 5=b+c
    [string]$UseClosePos  = 'true',                      # ③終値と青スパンの位置
    [string]$SlopeMode    = '2',                         # ④長期スパンの傾き 0=使わない 1〜5=何本前と比べるか
    [string]$EntryDelay   = '1',                         # エントリーを何本後の始値で出すか
    [string]$ExitDelay    = '1',                         # 決済を何本後の始値で出すか

    # 膠着（エントリーの追加条件）
    [string]$SqueezeUse       = '0',                     # 0=使わない 1=①帯の幅 2=②時刻別 3=③ケルトナー 4=④ばらつき 5=⑤値幅
    [string]$SqueezeTF        = '0',                     # 0=売買する足と同じ 1=1時間足 2=4時間足 3=日足
    [string]$SqueezePeriod    = '21',
    [string]$SqueezeLookback  = '120',
    [string]$SqueezeThreshold = '10.0',
    [string]$SqueezeKcMult    = '1.5',

    [string]$Lots = '0.10',

    [int]$TimeoutMin  = 480,
    [int]$WaitFreeSec = 90,                              # 同じ端末が空くまで待つ秒数
    [string]$Terminal = 'C:\Program Files\XM Trading MT5\terminal64.exe'
)

$ErrorActionPreference = 'Stop'

if ($Optimize -and -not $Report) {
    throw '総当たりでは -Report に結果 XML の絶対パスを指定してください。指定しないと結果が残りません。'
}

# 「開始:刻み:終了」なら振る、そうでなければ固定。
# MT5 の書式は 値||開始||刻み||終了||振るか(Y/N)。
function Format-TesterInput([string]$name, [string]$spec) {
    if ($spec -match '^\s*(-?[\d.]+)\s*:\s*(-?[\d.]+)\s*:\s*(-?[\d.]+)\s*$') {
        return "$name=$($Matches[1])||$($Matches[1])||$($Matches[2])||$($Matches[3])||Y"
    }
    return "$name=$spec||$spec||0||$spec||N"
}

# 同じデータフォルダを2つの端末が同時に使えないため、起動中だと設定が無視され、
# 走っていないのに成功したように見える。
#
# 判定は**実行ファイルのパスで行う**。プロセス名だけで見ると、別ブローカーの
# 端末（FXGT / OANDA）が起動しているだけで弾いてしまう。データフォルダが違う
# ので、それらは同時に動いていて構わない。
$termPath = (Resolve-Path $Terminal).Path
$deadline = (Get-Date).AddSeconds($WaitFreeSec)
while ($true) {
    $running = @(Get-Process -Name terminal64 -ErrorAction SilentlyContinue |
                 Where-Object { $_.Path -eq $termPath })
    if ($running.Count -eq 0) { break }
    if ((Get-Date) -gt $deadline) {
        Write-Error "MT5（$termPath）が起動中です (PID $($running.Id -join ', '))。$WaitFreeSec 秒待ちましたが閉じられませんでした。閉じてから実行してください。"
    }
    Write-Host "MT5 が起動中のため待機中… (PID $($running.Id -join ', '))"
    Start-Sleep -Seconds 5
}

$work = Join-Path $env:TEMP 'mql5-ea-lab-tester'
New-Item -ItemType Directory -Force $work | Out-Null
$ini = Join-Path $work "tester_$Tag.ini"

$inputLines = @(
    Format-TesterInput 'InpTenkan'          $Tenkan
    Format-TesterInput 'InpKijun'           $Kijun
    Format-TesterInput 'InpSpanB'           $SpanB
    Format-TesterInput 'InpLagBars'         $LagBars
    Format-TesterInput 'InpLagMode'         $LagMode
    Format-TesterInput 'InpUseClosePos'     $UseClosePos
    Format-TesterInput 'InpSlopeMode'       $SlopeMode
    Format-TesterInput 'InpEntryDelayBars'  $EntryDelay
    Format-TesterInput 'InpExitDelayBars'   $ExitDelay
    Format-TesterInput 'InpSqueezeUse'      $SqueezeUse
    Format-TesterInput 'InpSqueezeTF'       $SqueezeTF
    Format-TesterInput 'InpSqueezePeriod'   $SqueezePeriod
    Format-TesterInput 'InpSqueezeLookback' $SqueezeLookback
    Format-TesterInput 'InpSqueezeThreshold' $SqueezeThreshold
    Format-TesterInput 'InpSqueezeKcMult'   $SqueezeKcMult
    Format-TesterInput 'InpLots'            $Lots
    # 診断出力は結果を変えないが、単発テストではログに条件別の成立回数が
    # 出て切り分けに使える。総当たりでは1件ごとにログが膨らむだけなので切る。
    Format-TesterInput 'InpPrintCounters'   ($(if ($Optimize) { 'false' } else { 'true' }))
    Format-TesterInput 'InpShowIndicator'   'false'
)

$reportLines = if ($Report) { @("Report=$Report", 'ReplaceReport=1') } else { @() }

$body = @(
    '[Tester]'
    'Expert=mql5-ea-lab\EaSpanModel.ex5'
    "Symbol=$Symbol"
    "Period=$Period"
    "Model=$Model"
    "Optimization=$(if ($Optimize) { 1 } else { 0 })"   # 1 = 総当たり（全組み合わせ）
    'OptimizationCriterion=0'
    "FromDate=$From"
    "ToDate=$To"
    'ForwardMode=0'
    'Deposit=1000000'
    'Currency=JPY'
    'Leverage=1:500'
    'ExecutionMode=0'
    'ShutdownTerminal=1'
    'Visual=0'
    $reportLines
    ''
    '[TesterInputs]'
    $inputLines
) -join "`r`n"

[System.IO.File]::WriteAllText($ini, $body, [System.Text.Encoding]::Unicode)

Write-Host "設定: $ini"
Write-Host "実行: $Symbol $Period  $From 〜 $To  ティック=$Model  $(if ($Optimize) { '総当たり' } else { '単発' })  識別名=$Tag"
$inputLines | Where-Object { $_ -match '\|\|Y$' } | ForEach-Object { Write-Host "  振る: $_" }

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# 設定ファイルのパスは引用する。%TEMP% にユーザー名が入るため、名前に空白が
# あると引数が途中で切れる（/config: と本体の間に空白は入れない）。
$proc = Start-Process -FilePath $Terminal -ArgumentList "/config:`"$ini`"" -PassThru
$exited = $proc.WaitForExit($TimeoutMin * 60 * 1000)
$sw.Stop()

if (-not $exited) {
    # 起動したままにすると、次回以降が冒頭の起動中チェックで全部失敗する。
    # 自分が起動したプロセスだけを Id 指定で確実に終わらせる。
    Write-Warning "$TimeoutMin 分で終わりませんでした。起動した MT5 (PID $($proc.Id)) を終了します。"
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        $proc.WaitForExit(30 * 1000) | Out-Null
    }
    catch { Write-Warning "MT5 (PID $($proc.Id)) を終了できませんでした: $($_.Exception.Message)" }
    exit 1
}

Write-Host ("終了まで {0:N1} 分" -f $sw.Elapsed.TotalMinutes)

if ($Report) {
    # MT5 は拡張子を補うことがあるので、指定名で始まるものを探す。
    $dir  = Split-Path -Parent $Report
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Report)
    $found = @(Get-ChildItem $dir -Filter "$stem*" -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
    if ($found.Count -eq 0) {
        Write-Error "結果ファイルが見つかりません（$Report）。テスターのログを確認してください。"
    }
    Write-Host ("出力: {0}  ({1:N0} バイト)" -f $found[0].FullName, $found[0].Length)
}

# テスターのログには、EA が起動時に出す実際の設定と、終了時の条件別成立回数が
# 残る。**総当たりで取引ゼロが並んだときは、まずここを読む。** 設定が弾かれて
# いた場合も、条件が厳しかった場合も、結果表の見た目は同じになる。
$logDir = Join-Path $env:APPDATA 'MetaQuotes\Terminal\C4171FD2B38378D6406D5C84412B5F20\Tester\logs'
$latest = @(Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
if ($latest.Count -gt 0) { Write-Host "テスターのログ: $($latest[0].FullName)" }
