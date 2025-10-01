<#
.SYNOPSIS
  CSVのIP（またはホスト名）を上から順に tracert し、詳細ログ＋サマリを出力。

.DESCRIPTION
  判定ルール:
    - (1) 1ホップ目でタイムアウト → NG
    - (2) "Trace complete"（日英） → OK
    - (3) 指定IP(-OkAfterTimeoutIp) へ到達後に「タイムアウト」が N 回連続（N=-ConsecTimeoutsForOk）→ OK
        ※ -OkAfterTimeoutIp 未指定時は「ターゲットIPへ到達後」に同条件でOK
    - ホップ行が1つも無い場合 → NG

  ログ運用:
    - 既定は毎回新規ファイル（tracert_yyyymmdd_hhmmss.log）
    - -LogPath 指定＆既存あり＆-Append 無し → 自動リネーム（_yyyymmdd_hhmmss 付与）
    - -Append 指定 → 追記。ただしサマリは「直近実行分のみ」をログ先頭へ再配置

.PARAMETER CsvPath
  対象CSV。基本は "IP" 列。単一列CSVなら唯一列をIPとして扱う。

.PARAMETER LogPath
  ログ出力先。未指定時は自動命名。

.PARAMETER Append
  追記モード。今回サマリは先頭、既存本文は後段へ温存。

.PARAMETER MaxHops
  tracert /h（最大ホップ数）。既定 30。

.PARAMETER TimeoutMs
  tracert /w（各ホップの待ち時間 ms）。既定 4000。

.PARAMETER NoDns
  tracert /d（名前解決なし）。速度/安定性向上。

.PARAMETER DelayMsBetweenTargets
  宛先間スリープ(ms)。大量宛先時の緩和。

.PARAMETER ConsecTimeoutsForOk
  「到達後タイムアウト×N連続でOK」のN。既定 5。

.PARAMETER OkAfterTimeoutIp
  「このIPv4に到達後」のタイムアウト×N連続でOKとする基準IP。
  未指定時は対象ターゲットのIPv4で評価。
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$CsvPath,
    [string]$LogPath,                         # 未指定なら自動命名 tracert_yyyymmdd_hhmmss.log
    [switch]$Append,                          # 追記モード（サマリは直近分を先頭へ再配置）
    [int]$MaxHops = 30,                       # tracert /h
    [int]$TimeoutMs = 4000,                   # tracert /w (ms)
    [switch]$NoDns,                           # tracert /d
    [int]$DelayMsBetweenTargets = 0,          # 宛先間スリープ(ms)
    [int]$ConsecTimeoutsForOk = 5,            # 到達後タイムアウト×N連続でOK
    [string]$OkAfterTimeoutIp                 # 到達基準のIPv4
)

# ===== ヘルパー：UTF-8(BOM) で確実に書き出す =====
function Write-Utf8Bom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $bom   = [byte[]](0xEF,0xBB,0xBF)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        [System.IO.File]::WriteAllBytes($Path, $bom + $bytes)
    } else {
        $Content | Set-Content -Path $Path -Encoding utf8
    }
}

# ===== 前処理 =====
if (-not (Test-Path $CsvPath)) { Write-Error "CSV が見つかりません: $CsvPath"; exit 1 }

try { $rows = Import-Csv -Path $CsvPath } catch { Write-Error "CSV 読み込み失敗: $($_.Exception.Message)"; exit 1 }
if (-not $rows -or $rows.Count -eq 0) { Write-Error "CSV にデータ行がありません。"; exit 1 }

# "IP" 列が無い場合、単一列CSVなら唯一列をIPへ昇格
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

# OkAfterTimeoutIp は IPv4 のみ許容
$OkAfterTimeoutIpResolved = $null
if ($OkAfterTimeoutIp) {
    $tmpIp = $null
    if (-not [System.Net.IPAddress]::TryParse($OkAfterTimeoutIp, [ref]$tmpIp) -or $tmpIp.AddressFamily -ne 'InterNetwork') {
        Write-Error "OkAfterTimeoutIp は IPv4 アドレスで指定してください。例: -OkAfterTimeoutIp 203.0.113.45"
        exit 1
    }
    $OkAfterTimeoutIpResolved = $tmpIp.ToString()
}
# 関数内から参照できるよう script: へ
$script:OkAfterTimeoutIpResolved = $OkAfterTimeoutIpResolved

# ログファイルパス決定
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

# ===== 正規表現・ヘルパ =====
$reTimeoutAnyLang        = '(要求がタイムアウトしました|Request timed out)'
$reTraceCompleteAnyLang  = '(トレース[はを]完了しました。?|Trace complete\.?)'
$reHopLine               = '^\s*(\d+)\s'             # 行頭のホップ番号
$reIPv4                  = '(?<!\d)(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?!\d)'

function Resolve-FirstIPv4 {
    param([string]$HostOrIp)
    if ([System.Net.IPAddress]::TryParse($HostOrIp, [ref]([System.Net.IPAddress]$null))) { return $HostOrIp }
    try {
        $hosts = [System.Net.Dns]::GetHostAddresses($HostOrIp) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }
        if ($hosts) { return $hosts[0].ToString() }
    } catch { }
    return $null
}

# ===== ログ本文（詳細）とサマリ用のバッファ =====
$detailLog = New-Object System.Collections.Generic.List[string]
$results   = New-Object System.Collections.Generic.List[object]

# セッションヘッダ
$detailLog.Add( ('=' * 80) )
$detailLog.Add( "Trace session start : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
$detailLog.Add( "CSV                 : $CsvPath" )
$detailLog.Add( "MaxHops             : $MaxHops" )
$detailLog.Add( "TimeoutMs           : $TimeoutMs" )
$detailLog.Add( "NoDNS               : $($NoDns.IsPresent)" )
if ($OkAfterTimeoutIpResolved) { $detailLog.Add( "OkAfterTimeoutIp     : $OkAfterTimeoutIpResolved" ) }
$detailLog.Add( ('=' * 80) )
$detailLog.Add( '' )

# ===== 1ターゲット分の実行・判定 =====
function Invoke-TraceOne {
    param([Parameter(Mandatory=$true)][string]$Target)

    $targetTrim = $Target.Trim()
    if ([string]::IsNullOrWhiteSpace($targetTrim)) {
        return [pscustomobject]@{ Target=$Target; Verdict='NG'; Detail='empty target' }
    }

    # tracert 引数
    $args = @()
    if ($NoDns.IsPresent) { $args += '/d' }
    $args += '/h'; $args += "$MaxHops"
    $args += '/w'; $args += "$TimeoutMs"
    $args += "$targetTrim"

    # ターゲットヘッダ
    $detailLog.Add( ('-' * 80) )
    $detailLog.Add( "Target : $targetTrim" )
    $detailLog.Add( "Start  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
    $detailLog.Add( ('-' * 80) )
    $detailLog.Add( '' )

    # tracert 実行
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath "$env:WINDIR\System32\tracert.exe" -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $tmp
        $null = $proc.WaitForExit()
        $outText = Get-Content -Path $tmp -Raw
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }

    # 生ログを詳細へ
    if ($outText) {
        foreach ($ln in ($outText -split "`r?`n")) { $detailLog.Add($ln) }
    }
    $detailLog.Add('')

    # ===== 判定 =====
    $lines = @()
    if ($outText) { $lines = $outText -split "`r?`n" }

    # ★ ホップ行が1つも無い → NG
    $hopLines = $lines | Where-Object { $_ -match $reHopLine }
    if (-not $hopLines -or $hopLines.Count -eq 0) {
        $detailLog.Add( "End    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
        $detailLog.Add( "Result : NG (ホップ情報なし)" )
        $detailLog.Add( ('-' * 80) )
        $detailLog.Add( '' )
        return [pscustomobject]@{ Target=$targetTrim; Verdict='NG'; Detail='no hop lines' }
    }

    # (1) 1ホップ目がタイムアウト → NG
    $firstHopLine = $hopLines | Select-Object -First 1
    if ($firstHopLine -match $reTimeoutAnyLang) {
        $detailLog.Add( "End    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
        $detailLog.Add( "Result : NG (1ホップ目でタイムアウト)" )
        $detailLog.Add( ('-' * 80) )
        $detailLog.Add( '' )
        return [pscustomobject]@{ Target=$targetTrim; Verdict='NG'; Detail='first hop timeout' }
    }

    # (2) Trace complete → OK
    if ($outText -match $reTraceCompleteAnyLang) {
        $detailLog.Add( "End    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
        $detailLog.Add( "Result : OK (Trace complete)" )
        $detailLog.Add( ('-' * 80) )
        $detailLog.Add( '' )
        return [pscustomobject]@{ Target=$targetTrim; Verdict='OK'; Detail='trace complete' }
    }

    # (2.5) 最終ホップがターゲットIPならOK（言語に依存しないフォールバック）
    $targetIpForCheck = Resolve-FirstIPv4 -HostOrIp $targetTrim
    if ($targetIpForCheck) {
       $lastHop = ($lines | Where-Object { $_ -match $reHopLine } | Select-Object -Last 1)
       if ($lastHop) {
           $ipsLast = [regex]::Matches($lastHop, $reIPv4) | ForEach-Object { $_.Value }
           if ($ipsLast -and ($ipsLast -contains $targetIpForCheck)) {
               $detailLog.Add( "End    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
               $detailLog.Add( "Result : OK (last hop reached target IP)" )
               $detailLog.Add( ('-' * 80) )
               $detailLog.Add( '' )
               return [pscustomobject]@{ Target=$targetTrim; Verdict='OK'; Detail='trace complete (by last hop ip match)' }
           }
        }
     }


    # (3) 指定IP（or ターゲット）到達後に timeout × N 連続 → OK
    $arrivalIp = if ($script:OkAfterTimeoutIpResolved) { $script:OkAfterTimeoutIpResolved } else { Resolve-FirstIPv4 -HostOrIp $targetTrim }
    $destHopIndex = $null
    if ($arrivalIp) {
        for ($i=0; $i -lt $lines.Count; $i++) {
            $ln = $lines[$i]
            if ($ln -match $reHopLine) {
                $ips = [regex]::Matches($ln, $reIPv4) | ForEach-Object { $_.Value }
                if ($ips -and ($ips -contains $arrivalIp)) {
                    $destHopIndex = $i
                    break
                }
            }
        }
        if ($null -eq $destHopIndex) {
            $detailLog.Add("[DEBUG] 到達判定: arrivalIp=$arrivalIp に一致するホップ行は見つかりませんでした")
        }
    }

    if ($null -ne $destHopIndex) {
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
                    return [pscustomobject]@{
                        Target  = $targetTrim
                        Verdict = 'OK'
                        Detail  = "post-$arrivalIp ${ConsecTimeoutsForOk}x timeouts"
                    }
                }
            } else {
                $consecTimeout = 0   # 連続が切れる
            }
        }
    }

    # (4) 何にも該当しない → NG
    $detailLog.Add( "End    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
    $detailLog.Add( "Result : NG" )
    $detailLog.Add( ('-' * 80) )
    $detailLog.Add( '' )
    return [pscustomobject]@{ Target=$targetTrim; Verdict='NG'; Detail='no complete, no post-arrival timeouts' }
}

# ===== メインループ =====
$idx = 0
foreach ($row in $rows) {
    $idx++
    $ip = "$($row.IP)".Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) { continue }
    Write-Host "[$idx/$($rows.Count)] Tracing $ip ... (NoDNS=$($NoDns.IsPresent))"
    $res = Invoke-TraceOne -Target $ip

    # 逐次：ターミナルに判定を色付きで表示
    $color = if ($res.Verdict -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("    -> [{0}] {1}" -f $res.Verdict, $res.Detail) -ForegroundColor $color

    $results.Add([pscustomobject]@{
        No = $idx
        Target = $ip
        Verdict = $res.Verdict
        Detail  = $res.Detail
    })
    if ($DelayMsBetweenTargets -gt 0) { Start-Sleep -Milliseconds $DelayMsBetweenTargets }
}

# セッションフッタ
$detailLog.Add( ('=' * 80) )
$detailLog.Add( "Trace session end   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" )
$detailLog.Add( ('=' * 80) )

# ===== サマリ（直近実行分のみ）をログ冒頭へ =====
$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add("=== 結果一覧 ===")
foreach ($r in $results) {
    $summaryLines.Add( ("{0} {1}［{2}］" -f $r.No, $r.Target, $r.Verdict) )
}
$summaryLines.Add("=================")
$summaryText = ($summaryLines -join "`r`n")

# Append 時は既存ログ本文を後段へ温存
$existing = ""
if ($Append -and (Test-Path $LogPath)) {
    try { $existing = Get-Content -Path $LogPath -Raw -Encoding UTF8 } catch { $existing = "" }
}

# 最終テキスト：サマリ → 今回の詳細 → （Appendなら）旧本文
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

# UTF-8(BOM) で書き出し
Write-Utf8Bom -Path $LogPath -Content ($finalText -join "`r`n")

# 画面にもサマリを表示
Write-Host ""
Write-Host $summaryText
Write-Host ""
Write-Host "完了: $LogPath にサマリ＋詳細ログを書き込みました。"
