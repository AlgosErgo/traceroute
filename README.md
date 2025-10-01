# traceroute

使用例
```
powershell -ExecutionPolicy Bypass -File .\TraceFromCsv.ps1 -CsvPath .\targets.csv -OkAfterTimeoutIp 203.0.113.45 -ConsecTimeoutsForOk 3 -NoDns
```


ターミナル出力例
```
PS C:\Users\sr-server001\Desktop\test> powershell -ExecutionPolicy Bypass -File .\TraceFromCsv.ps1 -CsvPath .\targets.csv -OkAfterTimeoutIp 1.1.1.1 -ConsecTimeoutsForOk 3 -NoDns
ログ出力先: tracert_20251002_000449.log （Append=False / OkAfterTimeoutIp=1.1.1.1 / N=3）
[1/5] Tracing 1.1.1.1 ... (NoDNS=True)
    -> [OK] trace complete
[2/5] Tracing 8.8.8.8 ... (NoDNS=True)
    -> [OK] trace complete
[3/5] Tracing 192.168.2.1 ... (NoDNS=True)
    -> [OK] trace complete
[4/5] Tracing 192.168.1.1 ... (NoDNS=True)
    -> [OK] trace complete
[5/5] Tracing 192.168.12.1 ... (NoDNS=True)
    -> [OK] trace complete

=== 結果一覧 ===
1 1.1.1.1［OK］
2 8.8.8.8［OK］
3 192.168.2.1［OK］
4 192.168.1.1［OK］
5 192.168.12.1［OK］
=================

完了: tracert_20251002_000449.log にサマリ＋詳細ログを書き込みました。
PS C:\Users\sr-server001\Desktop\test>
```

ログファイルの中身イメージ
（冒頭サマリ → 詳細ログの順）
```
=== 結果一覧 ===
1 8.8.8.8［OK］
2 1.1.1.1［OK］
3 219.188.238.24［NG］
=================

================================================================================
Trace session start : 2025-10-01 23:05:00
CSV                 : .\targets.csv
MaxHops             : 30
TimeoutMs           : 4000
NoDNS               : True
OkAfterTimeoutIp     : 1.1.1.1
================================================================================

--------------------------------------------------------------------------------
Target : 8.8.8.8
Start  : 2025-10-01 23:05:01
--------------------------------------------------------------------------------
  1    <1 ms    <1 ms    <1 ms  192.168.2.1
  2    12 ms    11 ms    11 ms  203.0.113.1
  3    14 ms    15 ms    14 ms  8.8.8.8
トレースは完了しました。
End    : 2025-10-01 23:05:04
Result : OK (Trace complete)
--------------------------------------------------------------------------------

Target : 1.1.1.1
Start  : 2025-10-01 23:05:06
--------------------------------------------------------------------------------
  1    <1 ms    <1 ms    <1 ms  192.168.2.1
  2    10 ms    10 ms    9 ms   example.bbtec.net [219.188.238.24]
  3    12 ms    11 ms    12 ms  one.one.one.one [1.1.1.1]
要求がタイムアウトしました。
要求がタイムアウトしました。
要求がタイムアウトしました。
End    : 2025-10-01 23:05:13
Result : OK (指定IP 1.1.1.1 到達後にタイムアウト×3 連続)
--------------------------------------------------------------------------------
```



  ## 判定ルール:
    1. 1ホップ目でタイムアウト → NG
    2. "Trace complete"（日英） → OK
    3. 指定IP(-OkAfterTimeoutIp) へ到達後に「タイムアウト」が N 回連続（N=-ConsecTimeoutsForOk）→ OK
        ※ -OkAfterTimeoutIp 未指定時は「ターゲットIPへ到達後」に同条件でOK
    4. ホップ行が1つも無い場合 → NG

  ## ログ運用:
    - 既定は毎回新規ファイル（tracert_yyyymmdd_hhmmss.log）
    - -LogPath 指定＆既存あり＆-Append 無し → 自動リネーム（_yyyymmdd_hhmmss 付与）
    - -Append 指定 → 追記。ただしサマリは「直近実行分のみ」をログ先頭へ再配置




動作環境（要件）

OS：Windows 10 / 11、Windows Server 2016 以降（日本語/英語いずれもOK）
※ Windows 専用です（tracert.exe を使用）。Linux/macOS の PowerShell では動きません。

PowerShell：

Windows PowerShell 5.1（標準）

もしくは PowerShell 7.x（Core） on Windows

権限：標準ユーザーで可（管理者不要）

実行ポリシーが厳しい場合は、都度 -ExecutionPolicy Bypass で実行、または Set-ExecutionPolicy RemoteSigned -Scope CurrentUser を一度設定。

ネットワーク要件：

Windows の tracert は ICMP Echo（TTL 逐次増加）を使います。

経路上で ICMP が遮断されていると Request timed out が増えます（本スクリプトはその状態でも判定できるよう、到達後タイムアウト×N ルールを実装済み）。

宛先や中間ルータが ICMP を返さない設計の場合は、-ConsecTimeoutsForOk を活用（既定 5）。

DNS：

逆引きが遅い/不安定な環境では -NoDns 推奨（/d）。速度・安定性が向上します。

ファイル/文字コード：

スクリプトは UTF-8 (BOM付き) で保存（文字化け回避）。

ログの書き込み先フォルダに書き込み権限が必要。

CSV 仕様：

基本はヘッダ名 IP の列を参照。

単一列CSVなら自動でその列を IP とみなします。複数列で IP が無い場合はエラー。

行頭や末尾の空白は自動トリム。

判定の前提：

-OkAfterTimeoutIp は IPv4 アドレス必須（ホスト名不可）。

IPv6 トレースは未対応（必要なら tracert -6 対応を追加可能）。

70件を調査する際の運用ポイント

そのまま実行でOK：70件規模は問題ありません（スクリプトはシーケンシャルでメモリ使用も軽量）。

所要時間の考え方（上限目安の式）：
Windows tracert は 1ホップにつき3プローブ送ります。
1宛先の最悪時間 ≈ MaxHops × 3 × TimeoutMs
→ 宛先数が多いほどその合計になります。必要に応じて MaxHops や TimeoutMs を下げると短縮できます。
※ これは理論上の上限目安で、実測はネットワーク状況で大きく変わります。

おすすめ設定例（70件想定）：

まずは既定の -MaxHops 30 -TimeoutMs 4000 -NoDns で1～2件試し、状況に合わせて調整。

経路が短い/企業ネット内だけなら、-MaxHops 20～25、-TimeoutMs 2000～3000 にしても十分なことが多い。

大量宛先・装置配慮が必要なら -DelayMsBetweenTargets 100～300 で間隔を入れる。

ログ運用：

既定は毎回新しいログ名（tracert_yyyymmdd_hhmmss.log）。

特定ファイルに積み上げたい場合は -LogPath path -Append を使用（サマリは毎回先頭に直近分が入ります）。

多言語OS対応：

「到達完了」「タイムアウト」は日英の定型文を拾う正規表現で対応。別言語OSでも "* * *" パターンは多く、必要なら語句を追加可能。

よくある質問（簡潔版）

Q. 管理者は必要？ → いいえ、不要です（標準ユーザーでOK）。

Q. 社内で ICMP が絞られているが使える？ → はい。-ConsecTimeoutsForOk と -OkAfterTimeoutIp を併用すれば「到達まではOK、その後はFWでICMP抑止」という設計でも合否を判断可能。

Q. IPv6 宛先も混在する → 現行は IPv4 想定。必要なら -UseIPv6 のようなスイッチを追加して tracert -6 に切り替える改修が可能。
