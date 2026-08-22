# MT5 のストラテジーテスターを設定ファイル経由で自動実行する。
#
# 2026-08-20 に単発・総当たりの両方で実行を確認した。単発の結果は総当たりの
# レポートと取引数・損益が一致している。
#
# **MT5 はテスト後に自分を再起動することがある。** 連続して回すときは、毎回
# 呼ぶ前に閉じること（本スクリプトは起動中だと待って諦める）。
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
# 成績は EA が共有フォルダへ書く期間別 CSV で取る。
#   単発   … <PeriodCsv>_<銘柄>_<時間足>.csv
#   総当たり… <PeriodCsv>_<銘柄>_<時間足>_opt.csv（全パターンぶん・pass 列つき）
# 置き場所は %APPDATA%\MetaQuotes\Terminal\Common\Files\。

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

    # **総当たりでは MT5 が Report を書かない**（2026-08-20 実測。指定しても
    # ファイルは作られず、テスターのログにも記録が残らない）。総当たりの
    # 成績は EA が出す期間別 CSV で取る。順位・PF・最大DD が要るときだけ、
    # MT5 の画面から手で書き出すこと。
    [string]$Report = '',

    # エントリーのきっかけ 0=雲の色が変わったとき 1=膠着が始まったとき 2=どちらでも
    [string]$EntryTrigger = '0',

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

    # マクロ反応日での絞り込み 0=使わない 1=反応した日だけ 2=反応しなかった日だけ（対照）
    [string]$MacroUse = '0',

    [string]$Lots = '0.10',

    # 年別・月別の成績。CSV は共有フォルダ（Terminal\Common\Files）へ出る。
    # 識別名を混ぜて、連続実行で上書きし合わないようにする。
    [string]$PrintPeriods = 'true',
    [string]$PeriodCsv    = "p3_$Tag",

    # テストが終わっても MT5 を閉じない。画面で結果を見たいときに使う。
    # 閉じないので次の実行は手で閉じてから。待ち受けもしない（起動して戻る）。
    [switch]$KeepOpen,

    [int]$TimeoutMin  = 480,
    [int]$WaitFreeSec = 90,                              # 同じ端末が空くまで待つ秒数
    [string]$Terminal = 'C:\Program Files\XM Trading MT5\terminal64.exe'
)

$ErrorActionPreference = 'Stop'

if ($Optimize -and $PrintPeriods -ne 'true') {
    throw '総当たりの結果は期間別 CSV でしか残りません。-PrintPeriods true のまま実行してください。'
}

# 数値として認める形。`[\d.]+` だと `1.2.3` や `.` まで通り、MT5 は
# その入力を黙って無視して**前回使った値**で走る（走ったのに別条件）。
$NumRe = '-?(?:\d+(?:\.\d+)?|\.\d+)'

# 「開始:刻み:終了」なら振る、そうでなければ固定。
# MT5 の書式は 値||開始||刻み||終了||振るか(Y/N)。
function Format-TesterInput([string]$name, [string]$spec) {
    if ($spec -match "^\s*($NumRe)\s*:\s*($NumRe)\s*:\s*($NumRe)\s*$") {
        return "$name=$($Matches[1])||$($Matches[1])||$($Matches[2])||$($Matches[3])||Y"
    }

    # true/false は 0/1 へ直す。|| 形式は数値・列挙のための書式なので、
    # 文字のまま入れると解釈が処理系任せになる。
    $v = switch -Regex ($spec) { '^\s*true\s*$' { '1' } '^\s*false\s*$' { '0' } default { $spec } }

    # 文字列の入力に || 形式は使わない。区切り記号を値の一部と取り違える。
    if ($v -notmatch "^$NumRe$") { return "$name=$v" }

    return "$name=$v||$v||0||$v||N"
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
    Format-TesterInput 'InpEntryTrigger'    $EntryTrigger
    Format-TesterInput 'InpSqueezeUse'      $SqueezeUse
    Format-TesterInput 'InpSqueezeTF'       $SqueezeTF
    Format-TesterInput 'InpSqueezePeriod'   $SqueezePeriod
    Format-TesterInput 'InpSqueezeLookback' $SqueezeLookback
    Format-TesterInput 'InpSqueezeThreshold' $SqueezeThreshold
    Format-TesterInput 'InpSqueezeKcMult'   $SqueezeKcMult
    Format-TesterInput 'InpMacroUse'        $MacroUse
    Format-TesterInput 'InpLots'            $Lots
    # 診断出力は結果を変えないが、単発テストではログに条件別の成立回数が
    # 出て切り分けに使える。総当たりでは1件ごとにログが膨らむだけなので切る。
    Format-TesterInput 'InpPrintCounters'   ($(if ($Optimize) { 'false' } else { 'true' }))
    Format-TesterInput 'InpShowIndicator'   'false'
    # 総当たりでは EA 側が自動で抑止するが、設定は必ず書き出す（書かない
    # 入力は前回値を引き継ぐため）
    Format-TesterInput 'InpPrintPeriods'    $PrintPeriods
    Format-TesterInput 'InpPeriodCsv'       $PeriodCsv
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
    "ShutdownTerminal=$(if ($KeepOpen) { 0 } else { 1 })"
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

# **固定した項目も全部出す。** 指定しなかった項目は既定値で埋まるが、その
# 既定値が「使う」側のこともある。表示しないと、比較相手と違う条件で走って
# いても気づけない（2026-08-21 に発生。②③④を切らずにマクロ検証を回し、
# 前回の総当たりと比べられない結果を作った）。
$inputLines | Where-Object { $_ -notmatch '\|\|Y$' } | ForEach-Object {
    $n, $v = $_ -split '=', 2
    Write-Host ("  固定: {0,-22} {1}" -f $n, ($v -split '\|\|')[0])
}

# 起動時刻を控える。**今回の実行で書かれたレポートだけを成功と認めるため。**
# 同じ名前の古いレポートが残っていると、MT5 が書けずに終わっても前回の結果を
# 拾って成功に見える。秒未満を落とすのは、ファイル時刻の分解能が粗い環境で
# 自分が作ったファイルを取りこぼさないため。
$startedAt = (Get-Date).AddSeconds(-1)

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# 設定ファイルのパスは引用する。%TEMP% にユーザー名が入るため、名前に空白が
# あると引数が途中で切れる（/config: と本体の間に空白は入れない）。
$proc = Start-Process -FilePath $Terminal -ArgumentList "/config:`"$ini`"" -PassThru

if ($KeepOpen) {
    # 閉じない指定のときは終了を待てない（終了しないため）。出力の確認も
    # できないので行わない。結果は MT5 の画面で見る。
    $sw.Stop()
    Write-Host "MT5 (PID $($proc.Id)) を起動しました。テスト終了後も開いたままにします。"
    Write-Host "結果は MT5 の「ストラテジーテスター」で確認してください。"
    Write-Host "次に本スクリプトを実行するときは、先に MT5 を閉じてください。"
    return
}

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
    # **今回の実行で書かれたものだけを認める。** 古い同名レポートが残って
    # いると、MT5 が書けずに終わっても前回の結果を拾って成功に見える。
    $dir  = Split-Path -Parent $Report
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Report)
    $found = @(Get-ChildItem $dir -Filter "$stem*" -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -ge $startedAt } |
               Sort-Object LastWriteTime -Descending)
    if ($found.Count -eq 0) {
        Write-Error "今回の実行で書かれた結果ファイルがありません（$Report）。テスターのログを確認してください。同名の古いファイルがあっても成功とは扱いません。"
    }
    Write-Host ("出力: {0}  ({1:N0} バイト)" -f $found[0].FullName, $found[0].Length)
}

# **総当たりでは Report が書かれない**ので、上の確認は一度も走らない。成績は
# EA が共有フォルダへ出す期間別 CSV でしか残らないため、そちらを成功条件に
# する。EA の OnTesterInit() は CSV を開けなくても起動を続けるので、共有
# フォルダの設定ミスや書き込み失敗があっても、確認しなければ成功に見える。
if ($PrintPeriods -eq 'true') {
    $common = Join-Path $env:APPDATA 'MetaQuotes\Terminal\Common\Files'
    $suffix = if ($Optimize) { '_opt' } else { '' }
    $csv    = Join-Path $common ("{0}_{1}_PERIOD_{2}{3}.csv" -f $PeriodCsv, $Symbol, $Period, $suffix)

    # 古いファイルが残っていても成功と扱わない（Report 側と同じ考え方）。
    $item = Get-Item -LiteralPath $csv -ErrorAction SilentlyContinue
    if (-not $item -or $item.LastWriteTime -lt $startedAt) {
        Write-Error "今回の実行で書かれた期間別 CSV がありません（$csv）。共有フォルダの場所と、テスターのログの [期間別] 行を確認してください。"
    }
    Write-Host ("期間別 CSV: {0}  ({1:N0} バイト)" -f $item.FullName, $item.Length)
}

# テスターのログには、EA が起動時に出す実際の設定と、終了時の条件別成立回数が
# 残る。**総当たりで取引ゼロが並んだときは、まずここを読む。** 設定が弾かれて
# いた場合も、条件が厳しかった場合も、結果表の見た目は同じになる。
$logDir = Join-Path $env:APPDATA 'MetaQuotes\Terminal\C4171FD2B38378D6406D5C84412B5F20\Tester\logs'
$latest = @(Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
if ($latest.Count -gt 0) { Write-Host "テスターのログ: $($latest[0].FullName)" }
