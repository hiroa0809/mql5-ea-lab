# MT5 のストラテジーテスターを設定ファイル経由で自動実行する。
#
# MT5 は /config:<ini> を渡すと、テスターを回して自分で終了する。これで
# 人手を介さずに条件を変えた連続実行ができる。
#
# 前提: MT5 を閉じておくこと。同じデータフォルダを2つの端末が同時に使え
# ないため、起動中だと新しい設定が無視されて既存のウィンドウが前面に出る
# だけになる。走らせたつもりで何も起きない状態になるので、ここで弾く。
#
# **売買結果を変える入力は全部 [TesterInputs] に書く。** 書かなかった入力は
# ソースの初期値ではなく、**テスターが前回使った値**を引き継ぐ。手で最適化を
# 回した後などに前の設定が残り、気づかないまま別条件で走る（2026-08-12 に
# ④拡大の本数が 8 のまま引き継がれ、取引数が 2104 → 1918 とずれた）。
#
# 結果は EA 自身が共有フォルダへ CSV で書く（r1_<Tag>_trades.csv /
# _summary.csv）。テスターの標準レポートは口座通貨での純損益しか出さず、
# 判定に使うスプレッド抜きのグロス損益が取れないため。
#
# その標準レポート（Report=）は出力させない。使わないうえ、保存の途中で
# 固まることがあり（2026-08-12 に発生）、そこで止まると連続実行が進まない。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Tag,           # 実行の識別名。CSV の名前になる
    [Parameter(Mandatory)][string]$From,          # 2018.11.01
    [Parameter(Mandatory)][string]$To,            # 2022.12.31
    [string]$Symbol   = 'USDJPY#',
    [string]$Period   = 'M5',
    [int]$Exit        = 0,                        # 決済の方式 0=A 1=B 2=C
    [int]$Period_     = 21,                       # 期間（センターラインとσ）
    [int]$LagBars     = 21,                       # 遅行線の本数
    [int]$UseSqueeze  = 1,                        # ①膠着を条件に入れる
    [int]$SqueezeBars = 21,                       # ①膠着とみなす本数
    [double]$SigmaMult = 3.0,                     # ①③で使うσの倍数
    [int]$UseExpand   = 1,                        # ④バンド幅の拡大を条件に入れる
    [int]$ExpandBars  = 3,                        # ④拡大を見る本数
    [int]$UseSL       = 0,                        # 損切りを使う
    [double]$SLSigma  = 2.0,                      # 損切り（σの何倍）
    [int]$UseTimeStop = 0,                        # 保有本数で手仕舞う
    [int]$HoldBars    = 24,                       # 手仕舞うまでの本数
    [int]$Reverse     = 1,                        # 反対シグナルでドテンする
    [double]$Lots     = 0.10,                     # ロット
    [int]$StagedMode  = 0,                        # 段階エントリー 0=使わない 1=装填1のみ 2=装填1+装填2
    [int]$ArmBars     = 42,                       # 装填が生きている本数
    [int]$RsiPeriod   = 14,                       # RSI の期間
    [double]$RsiUpper = 80,                       # 買いの発火を見送る RSI
    [double]$RsiLower = 20,                       # 売りの発火を見送る RSI
    [int]$Model       = 2,                        # 2=始値のみ（本 EA は足の始値でしか売買しないため過不足なし）
    [int]$TimeoutMin  = 120,
    [int]$WaitFreeSec = 90,                       # 同じ端末が空くまで待つ秒数
    [string]$Terminal = 'C:\Program Files\XM Trading MT5\terminal64.exe'
)

$ErrorActionPreference = 'Stop'

# 同じデータフォルダを2つの端末が同時に使えないため、起動中だと設定が
# 無視され、走っていないのに成功したように見える。
#
# 判定は**実行ファイルのパスで行う**。プロセス名だけで見ると、別ブローカー
# の端末（FXGT / OANDA）が起動しているだけで弾いてしまう。データフォルダが
# 違うので、それらは同時に動いていて構わない。
#
# 他システムが一時的に開いていることがあるので、すぐ諦めず少し待つ。
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

$common = Join-Path $env:APPDATA 'MetaQuotes\Terminal\Common\Files'
$work   = Join-Path $env:TEMP 'mql5-ea-lab-tester'
New-Item -ItemType Directory -Force $work | Out-Null

$ini = Join-Path $work "tester_$Tag.ini"
@"
[Tester]
Expert=mql5-ea-lab\EaSpanBollinger.ex5
Symbol=$Symbol
Period=$Period
Model=$Model
Optimization=0
FromDate=$From
ToDate=$To
ForwardMode=0
Deposit=1000000
Currency=JPY
Leverage=1:500
ExecutionMode=0
ShutdownTerminal=1
Visual=0

[TesterInputs]
InpLots=$Lots
InpReverseOnOpposite=$Reverse
InpR1_Period=$Period_
InpR1_LagBars=$LagBars
InpR1_UseSqueeze=$UseSqueeze
InpR1_SqueezeBars=$SqueezeBars
InpR1_SigmaMult=$SigmaMult
InpR1_UseExpand=$UseExpand
InpR1_ExpandBars=$ExpandBars
InpR1_Exit=$Exit
InpR1_UseSL=$UseSL
InpR1_SLSigma=$SLSigma
InpR1_UseTimeStop=$UseTimeStop
InpR1_HoldBars=$HoldBars
InpR1_StagedMode=$StagedMode
InpR1_ArmBars=$ArmBars
InpR1_RsiPeriod=$RsiPeriod
InpR1_RsiUpper=$RsiUpper
InpR1_RsiLower=$RsiLower
InpRunTag=$Tag
"@ | Set-Content -Path $ini -Encoding ASCII

Write-Host "設定: $ini"
Write-Host "実行: $Symbol $Period  $From 〜 $To  決済方式=$Exit  段階=$StagedMode  RSI=$RsiUpper/$RsiLower  識別名=$Tag"

$beforeTrades  = @(Get-ChildItem $common -Filter "r1_${Tag}_trades*.csv"  -ErrorAction SilentlyContinue).Count
$beforeSummary = @(Get-ChildItem $common -Filter "r1_${Tag}_summary*.csv" -ErrorAction SilentlyContinue).Count
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# 設定ファイルのパスは引用する。%TEMP% にユーザー名が入るため、名前に
# 空白があると引数が途中で切れる。MT5 の仕様上も、空白を含むパスは
# 引用が必要（/config: と本体の間に空白は入れない）
$proc = Start-Process -FilePath $Terminal -ArgumentList "/config:`"$ini`"" -PassThru
$exited = $proc.WaitForExit($TimeoutMin * 60 * 1000)
$sw.Stop()

if (-not $exited) {
    # 起動したままにすると、次回以降が冒頭の起動中チェックで全部失敗する。
    # 自分が起動したプロセスだけを、Id 指定で確実に終わらせる
    Write-Warning "$TimeoutMin 分で終わりませんでした。起動した MT5 (PID $($proc.Id)) を終了します。"
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        $proc.WaitForExit(30 * 1000) | Out-Null
    }
    catch { Write-Warning "MT5 (PID $($proc.Id)) を終了できませんでした: $($_.Exception.Message)" }
    exit 1
}

Write-Host ("終了まで {0:N1} 分" -f $sw.Elapsed.TotalMinutes)

# trades と summary は EA が別々に開いて書くので、片方だけ失敗しうる。
# 両方が増えたことを確かめないと、欠けたまま成功として扱ってしまう
$afterTrades  = @(Get-ChildItem $common -Filter "r1_${Tag}_trades*.csv"  -ErrorAction SilentlyContinue)
$afterSummary = @(Get-ChildItem $common -Filter "r1_${Tag}_summary*.csv" -ErrorAction SilentlyContinue)
if ($afterTrades.Count -le $beforeTrades -or $afterSummary.Count -le $beforeSummary) {
    Write-Error ("CSV が揃っていません（trades {0}→{1} / summary {2}→{3}）。EA が起動していないか、途中で失敗しています。テスターのログを確認してください。" -f
                 $beforeTrades, $afterTrades.Count, $beforeSummary, $afterSummary.Count)
}

$afterTrades + $afterSummary | Sort-Object LastWriteTime -Descending | Select-Object -First 2 |
    ForEach-Object { Write-Host ("出力: {0}  ({1:N0} バイト)" -f $_.FullName, $_.Length) }
