# MT5 のストラテジーテスターを設定ファイル経由で自動実行する。
#
# MT5 は /config:<ini> を渡すと、テスターを回して自分で終了する。これで
# 人手を介さずに条件を変えた連続実行ができる。
#
# 前提: MT5 を閉じておくこと。同じデータフォルダを2つの端末が同時に使え
# ないため、起動中だと新しい設定が無視されて既存のウィンドウが前面に出る
# だけになる。走らせたつもりで何も起きない状態になるので、ここで弾く。
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
    [int]$UseSqueeze  = 1,                        # ①膠着を条件に入れる 0=入れない 1=入れる
    [int]$SqueezeBars = 21,                       # ①膠着とみなす本数
    [int]$ExpandBars  = 3,                        # ④拡大を見る本数
    [int]$StagedMode  = 0,                        # 段階エントリー 0=使わない 1=装填1のみ 2=装填1+装填2
    [double]$RsiUpper = 80,                       # 買いの発火を見送る RSI
    [double]$RsiLower = 20,                       # 売りを見送る RSI
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
InpR1_Exit=$Exit
InpR1_UseSqueeze=$UseSqueeze
InpR1_SqueezeBars=$SqueezeBars
InpR1_ExpandBars=$ExpandBars
InpR1_StagedMode=$StagedMode
InpR1_RsiUpper=$RsiUpper
InpR1_RsiLower=$RsiLower
InpRunTag=$Tag
"@ | Set-Content -Path $ini -Encoding ASCII

Write-Host "設定: $ini"
Write-Host "実行: $Symbol $Period  $From 〜 $To  決済方式=$Exit  段階=$StagedMode  RSI=$RsiUpper/$RsiLower  識別名=$Tag"

$before = @(Get-ChildItem $common -Filter "r1_${Tag}_*" -ErrorAction SilentlyContinue).Count
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$proc = Start-Process -FilePath $Terminal -ArgumentList "/config:$ini" -PassThru
$exited = $proc.WaitForExit($TimeoutMin * 60 * 1000)
$sw.Stop()

if (-not $exited) {
    Write-Warning "$TimeoutMin 分で終わりませんでした。MT5 は起動したままです。"
    exit 1
}

Write-Host ("終了まで {0:N1} 分" -f $sw.Elapsed.TotalMinutes)

$after = @(Get-ChildItem $common -Filter "r1_${Tag}_*" -ErrorAction SilentlyContinue)
if ($after.Count -le $before) {
    Write-Error "CSV が増えていません。EA が起動していないか、途中で失敗しています。テスターのログを確認してください。"
}

$after | Sort-Object LastWriteTime -Descending | Select-Object -First 2 |
    ForEach-Object { Write-Host ("出力: {0}  ({1:N0} バイト)" -f $_.FullName, $_.Length) }
