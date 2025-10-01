<#
.SYNOPSIS
  CSVのIP（またはホスト名）を上から順に tracert し、詳細ログ＋サマリを出力する。

.DESCRIPTION
  - 1ホップ目でタイムアウト → NG
  - "Trace complete"（日英対応） → OK
  - 【可変ルール】指定IP( -OkAfterTimeoutIp ) へ到達後に "タイムアウト" が N 回連続（N = -ConsecTimeoutsForOk） → OK
    ※ -OkAfterTimeoutIp 未指定なら「ターゲット到達後にタイムアウト×N連続」を適用

  ログファイルは既定で毎回新規作成（"tracert_yyyymmdd_hhmmss.log"）。
  - -LogPath を指定して既存がある＆-Append なし → 自動で別名（末尾に日時）へリネーム保存
  - -Append 指定 → 指定のログに追記。ただしサマリは「直近実行分のみ」をログの先頭へ再配置

.PARAMETER CsvPath
  トレース対象を記したCSVファイルのパス。既定で "IP" 列を参照。
  列名が "IP" でなく単一列CSVなら、その唯一列を IP として扱う。

.PARAMETER LogPath
  ログ出力ファイルのパス。未指定なら "tracert_yyyymmdd_hhmmss.log" を自動生成。
  指定先が既に存在し、-Append を付けない場合は "name_yyyymmdd_hhmmss.log" に自動リネームして保存。

.PARAMETER Append
  ログへの追記モード。既存ファイルに追記し、今回分のサマリはログ冒頭へ差し替え挿入する。
  既定（未指定）は毎回新規作成運用。

.PARAMETER MaxHops
  tracert の最大ホップ数（/h）。到達不可でもここで打ち切る。

.PARAMETER TimeoutMs
  tracert の各ホップ待ち時間（/w, ミリ秒）。値を小さくすると短時間で終了するが結果の * が増えやすい。

.PARAMETER NoDns
  tracert の /d 相当。名前解決をせず、純粋なIPのみで高速化する。

.PARAMETER DelayMsBetweenTargets
  各ターゲットの実行間に入れるスリープ（ミリ秒）。装置負荷やDoS誤検知の抑制に。

.PARAMETER ConsecTimeoutsForOk
  「到達後にタイムアウトが連続で何回続いたらOKとみなすか」の閾値（既定5）。
  監視機器やFWが宛先へのICMP応答を抑止する構成で、到達確認だけ欲しい際に有効。

.PARAMETER OkAfterTimeoutIp
  「このIPに到達した**のち**にタイムアウト×N連続でOK」を評価する基準IP。
  未指定時は「ターゲット自身に到達後」の評価にフォールバック。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\TraceFromCsv.ps1 -CsvPath .\targets.csv

.EXAMPLE
  .\TraceFromCsv.ps1 -CsvPath .\targets.csv -LogPath .\trace.log -Append -OkAfterTimeoutIp 203.0.113.45 -ConsecTimeoutsForOk 5

.NOTES
  - 文字コードは UTF-8 (BOM付き) で保存推奨（メモ帳でも可）
  - 実行ポリシーは Bypass で一時実行 or CurrentUser スコープで RemoteSigned 推奨
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$CsvPath,                         # 入力CSVへのフル/相対パス。"IP" 列が基本。単一列CSVなら自動でその列をIP扱い。
    [string]$LogPath,                         # 未指定なら "tracert_yyyymmdd_hhmmss.log" を自動生成。
    [switch]$Append,                          # 追記モード。既存ログの先頭に今回のサマリを再配置し、末尾に旧本文を温存。
    [int]$MaxHops = 30,                       # tracert /h : 到達できなくても ここで打切り。大きすぎると時間がかかる。
    [int]$TimeoutMs = 4000,                   # tracert /w : 各ホップの待ち時間(ms)。回線/装置の性質に合わせて調整。
    [switch]$NoDns,                           # tracert /d : 名前解決を抑止し速度向上。DNSが不安定な環境にも有効。
    [int]$DelayMsBetweenTargets = 0,          # 各ターゲットの間に入れるスリープ(ms)。大量宛先時の緩和に。
    [int]$ConsecTimeoutsForOk = 5,            # 「到達後タイムアウト×N連続でOK」のN。FW/IDS対策で宛先応答が無い構成向け。
    [string]$OkAfterTimeoutIp                 # 指定IPに到達した後のタイムアウト×NでOK判定したい“到達判定IP”（IPv4想定）。
)

# ========== 前処理 ==========
# 入力CSVの存在確認：無ければ即中断。メッセージは日本語で明確に。
if (-not (Test-Path $CsvPath)) { Write-Error "CSV が見つかりません: $CsvPath"; exit 1 }

# CSV読み込み："IP" 列前提。単一列CSVは唯一列をIPとみなす。
try { $rows = Import-Csv -Path $CsvPath } catch { Write-Error "CSV 読み込み失敗: $($_.Exception.Message)"; exit 1 }
if (-not $rows -or $rows.Count -eq 0) { Write-Error "CSV にデータ行がありません。"; exit 1 }

# 列名が "IP" でない場合のフォールバック：唯一列をIPにコピー（複数列はエラー）
if (-not ($rows | Get-Member -Name 'IP' -MemberType NoteProperty)) {
    $first = $rows | Select-Object -First 1
    $props = $first.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' }
    if ($props.Count -eq 1) {
        $onlyName = $props.Name
        $rows | ForEach-Object { $_ | Add-Member -NotePropertyName IP -NotePropertyValue $_.$onlyName -Force }
    } else {
        Write-Error "CSV に 'IP' 列が存在しません。ヘッダーを 'IP' にするか、単一列CSVにしてください。"
        exit 1
    }
}

# -OkAfterTimeoutIp の書式チェック：IPv4のみ許容。曖昧なホスト名は誤判定の原因なのでここでは弾く。
$OkAfterTimeoutIpResolved = $null
if ($OkAfterTimeoutIp) {
    $tmpIp = $null
    if (-not [System.Net.IPAddress]::TryParse($OkAfterTimeoutIp, [ref]$tmpIp) -or $tmpIp.AddressFamily -ne 'InterNetwork') {
        Write-Error "OkAfterTimeoutIp は IPv4 アドレスで指定してください。例: -OkAfterTimeoutIp 203.0.113.45"
        exit 1
    }
    $OkAfterTimeoutIpResolved = $tmpIp.ToString()
}

# ログファイルパスの決定ロジック：
#  - 未指定 → "tracert_yyyymmdd_hhmmss.log"
#  - 指定＆既存あり＆Appendなし → 自動リネーム（上書き事故回避）
$timestamp = (Get-Date -Format "yyyyMMdd_HHmmss")
if (-not $LogPath -or [string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = "tracert_$timestamp.log"
} elseif (-not $Append) {
    if (Test-Path $LogPath) {
        $dir  = Split-Path $LogPath -Parent; if (-not $dir) { $dir = "." }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($LogPath)
        $ext  = [System.IO.Path]::GetExtension($LogPath)
        $LogPath = Join-Path $dir "$($base)_$timestamp$ext"
    }
}
Write-Host "ログ出力先: $LogPath （Append=$($Append.IsPresent) / OkAfterTimeoutIp=$OkAfterTimeoutIpResolved / N=$ConsecTimeoutsForOk）"

# 正規表現・ヘルパ
#  - reTimeoutAnyLang：日英の "要求がタイムアウトしました / Request timed out" に対応
#  - reTraceCompleteAnyLang：日英の "トレースは完了しました / Trace complete" に対応
#  - reHopLine：ホップ行判定（行頭の番号で判別、可変空白許容）
$reTimeoutAnyLang        = '(要求がタイムアウトしました|Request timed out)'
$reTraceCompleteAnyLang  = '(トレースは完了しました|Trace complete)'
$reHopLine               = '^\s*(\d+)\s'

# ホスト名が来たときに最初のIPv4を得る（tracert 出力との突合せ用途）
function Resolve-FirstIPv4 {
    param([string]$HostOrIp)
    if ([System.Net.IPAddress]::TryParse($HostOrIp, [ref]([System.Net.IPAddress]$null))) { return $HostOrIp }
    try {
        $hosts = [System.Net.Dns]::GetHostAddresses($HostOrIp) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }
        if ($hosts) { return $hosts[0].ToString() }  # Aレコードの先頭を採用
    } catch { }
    return $null
}

# ========== ログ本文はメモリに貯めて最後に書く（サマリを先頭へ差し込むため） ==========
$detailLog = New-Object System.Collections.Generic.List[string]   # 詳細ログ（tracert出力＋判定メタ）
$results   = New-Object System.Collections.Generic.List[object]  # サマリ生成用（No/Target/Verdict/Detail）

# セッションヘッダ（再現性・環境差異の追跡に役立つ）
$detailLog.Add( ('=' * 80) )
$detailLog.Add( "Trace session start : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
$detailLog.Add( "CSV                 : $CsvPath" )
$detailLog.Add( "MaxHops             : $MaxHops" )
$detailLog.Add( "TimeoutMs           : $TimeoutMs" )
$detailLog.Add( "NoDNS               : $($NoDns.IsPresent)" )
if ($OkAfterTimeoutIpResolved) { $detailLog.Add( "OkAfterTimeoutIp     : $OkAfterTimeoutIpResolved" ) }
$detailLog.Add( ('=' * 80) )
$detailLog.Add( '' )

# 1ターゲット分の実行と判定
function Invoke-TraceOne {
    param([Parameter(Mandatory=$true)][string]$Target)

    $targetTrim = $Target.Trim()
    if ([string]::IsNullOrWhiteSpace($targetTrim)) {
        return [pscustomobject]@{ Target=$Target; Verdict='NG'; Detail='empty target' }
    }

    # tracert 引数を丁寧に構成（/d /h /w の順序は問わないが読みやすさ重視で固定）
    $args = @()
    if ($NoDns.IsPresent) { $args += '/d' }
    $args += '/h'; $args += "$MaxHops"
    $args += '/w'; $args += "$TimeoutMs"
    $args += "$targetTrim"

    # ---- 出力ヘッダ（ターゲット単位）----
    $detailLog.Add( ('-' * 80) )
    $detailLog.Add( "Target : $targetTrim" )
    $detailLog.Add( "Start  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
    $detailLog.Add( ('-' * 80) )
    $detailLog.Add( '' )

    # tracert 実行（Start-Process + RedirectStandardOutput で文字化け/混入を避ける）
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath "$env:WINDIR\System32\tracert.exe" -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $tmp
        $null = $proc.WaitForExit()
        $outText = Get-Content -Path $tmp -Raw
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }

    # 生ログをそのまま詳細ログへ（改行ごとにAdd）
    if ($outText) {
        foreach ($ln in ($outText -split "`r?`n")) { $detailLog.Add($ln) }
    }
    $detailLog.Add('')

    # ===== 判定ロジック =====
    $lines = @()
    if ($outText) { $lines = $outText -split "`r?`n" }

    # (1) 1ホップ目がタイムアウト → NG（ゲートウェイ未達＝ローカル/配下問題の可能性が高い）
    $firstHopLine = $lines | Where-Object { $_ -match $reHopLine } | Select-Object -First 1
    if ($null -ne $firstHopLine) {
        if ($firstHopLine -match $reTimeoutAnyLang) {
            $detailLog.Add( "End    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
            $detailLog.Add( "Result : NG (1ホップ目でタイムアウト)" )
            $detailLog.Add( ('-' * 80) )
            $detailLog.Add( '' )
            return [pscustomobject]@{ Target=$targetTrim; Verdict='NG'; Detail='first hop timeout' }
        }
    }

    # (2) "Trace complete" → OK（OS言語差異を考慮し日英両対応）
    if ($outText -match $reTraceCompleteAnyLang) {
        $detailLog.Add( "End    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
        $detailLog.Add( "Result : OK (Trace complete)" )
        $detailLog.Add( ('-' * 80) )
        $detailLog.Add( '' )
        return [pscustomobject]@{ Target=$targetTrim; Verdict='OK'; Detail='trace complete' }
    }

    # (3) 指定IP（あるいはターゲット）到達後にタイムアウト×N連続 → OK
    #     - OkAfterTimeoutIp があればそれを優先（"post-このIP" のタイムアウト列を評価）
    #     - 無ければターゲットIP（ホスト名はA解決の先頭IPv4）で到達判定
    $arrivalIp = if ($script:OkAfterTimeoutIpResolved) { $script:OkAfterTimeoutIpResolved } else { Resolve-FirstIPv4 -HostOrIp $targetTrim }
    $destHopIndex = $null
    if ($arrivalIp) {
        for ($i=0; $i -lt $lines.Count; $i++) {
            $ln = $lines[$i]
            if ($ln -match $reHopLine) {
                if ($ln -match [regex]::Escape($arrivalIp)) { $destHopIndex = $i; break }
            }
        }
    }

    if ($null -ne $destHopIndex) {
        # 到達以降の行で "Request timed out/要求がタイムアウトしました" が N 回連続したら OK
        $consecTimeout = 0
        for ($j=$destHopIndex+1; $j -lt $lines.Count; $j++) {
            $ln2 = $lines[$j]
            if ($ln2 -match $reTimeoutAnyLang) {
                $consecTimeout++
                if ($consecTimeout -ge $ConsecTimeoutsForOk) {
                    $label = if ($script:OkAfterTimeoutIpResolved) {
                        "OK (指定IP $script:OkAfterTimeoutIpResolved 到達後にタイムアウト×$ConsecTimeoutsForOk 連続)"
                    } else {
                        "OK (宛先到達後にタイムアウト×$ConsecTimeoutsForOk 連続)"
                    }
                    $detailLog.Add( "End    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
                    $detailLog.Add( "Result : $label" )
                    $detailLog.Add( ('-' * 80) )
                    $detailLog.Add( '' )
                    return [pscustomobject]@{ Target=$targetTrim; Verdict='OK'; Detail="post-$arrivalIp $ConsecTimeoutsForOk consecutive timeouts" }
                }
            } else {
                # 連続カウントは途切れる（間に応答が混ざったら「連続」ではない）
                $consecTimeout = 0
            }
        }
    }

    # (4) ここまで何にも該当しなければ NG（中間での到達が認められない／タイムアウト連続条件を満たさない等）
    $detailLog.Add( "End    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
    $detailLog.Add( "Result : NG" )
    $detailLog.Add( ('-' * 80) )
    $detailLog.Add( '' )
    return [pscustomobject]@{ Target=$targetTrim; Verdict='NG'; Detail='no complete, no post-arrival timeouts' }
}

# ========== メインループ ==========
$idx = 0
foreach ($row in $rows) {
    $idx++
    $ip = "$($row.IP)".Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) { continue }  # 空行スキップ
    Write-Host "[$idx/$($rows.Count)] Tracing $ip ..."
    $res = Invoke-TraceOne -Target $ip
    $results.Add([pscustomobject]@{
        No = $idx
        Target = $ip
        Verdict = $res.Verdict
        Detail  = $res.Detail
    })
    if ($DelayMsBetweenTargets -gt 0) { Start-Sleep -Milliseconds $DelayMsBetweenTargets }
}

# セッションフッタ（実行ウィンドウの境界としても役立つ）
$detailLog.Add( ('=' * 80) )
$detailLog.Add( "Trace session end   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
$detailLog.Add( ('=' * 80) )

# ========== サマリ（直近実行分のみ）をログ冒頭へ ==========
$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add("=== 結果一覧 ===")
foreach ($r in $results) {
    $summaryLines.Add( ("{0} {1}［{2}］" -f $r.No, $r.Target, $r.Verdict) )
}
$summaryLines.Add("=================")
$summaryText = ($summaryLines -join "`r`n")

# 追記モード時のみ、既存ログを後段へ温存して結合
$existing = ""
if ($Append -and (Test-Path $LogPath)) {
    try { $existing = Get-Content -Path $LogPath -Raw -Encoding UTF8 } catch { $existing = "" }
}

# 最終書き出し：サマリ → 今回の詳細 → （Appendなら）旧ログ本文
$finalText = @()
$finalText += $summaryText
$finalText += ""
$finalText += ($detailLog -join "`r`n")
if ($Append) {
    if ($existing -and $existing.Trim().Length -gt 0) {
        $finalText += ""
        $finalText += $existing
    }
}

# 文字コードはUTF-8（BOM付き）で統一。Windows環境での文字化け回避に有効。
$finalText -join "`r`n" | Set-Content -Path $LogPath -Encoding utf8

# 画面にもサマリを表示（CI等で標準出力を拾う用途に便利）
Write-Host ""
Write-Host $summaryText
Write-Host ""
Write-Host "完了: $LogPath にサマリ＋詳細ログを書き込みました。"
