<#
  verify_excel_com.ps1  （開発用・Windows + Microsoft Excel が必要）

  生成した解説ブック（.xlsx）を実物の Excel（COM）で開き、
    - 修復（「一部の内容に問題が見つかりました」）が発生しないこと（%TEMP%\error*.xml の増加で検出）
    - 標準スタイルのフォントが Meiryo UI であること
    - 各シートの使用範囲・行数・目盛線・見出しセル（B2）と本文セルのフォント
    - 本文の行が切れていないか（折り返し行の高さが 0 や極端に小さくないか）
  を確認し、ブック全体を PDF に書き出す。-Capture を付けると、指定シートの先頭を画面どおりの PNG に保存する。

  使い方:
    powershell -NoProfile -ExecutionPolicy Bypass -File verify_excel_com.ps1 -Path book.xlsx [-Pdf out.pdf] [-Capture "00_表紙,05_動作イメージ"] [-OutDir dir]
#>
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$Pdf = "",
  [string]$Capture = "",
  [string]$OutDir = ""
)
$ErrorActionPreference = 'Stop'
$Path = (Resolve-Path $Path).Path
if (-not $OutDir) { $OutDir = Split-Path $Path }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
if (-not $Pdf) { $Pdf = Join-Path $OutDir ([IO.Path]::GetFileNameWithoutExtension($Path) + '.pdf') }

$before = @(Get-ChildItem -Path $env:TEMP -Filter 'error*.xml' -ErrorAction SilentlyContinue | ForEach-Object FullName)
$problems = 0

$xl = New-Object -ComObject Excel.Application
try {
  $xl.Visible = ($Capture -ne "")
  $xl.DisplayAlerts = $false
  $wb = $xl.Workbooks.Open($Path, 0, $true)
  "Opened : $($wb.Name)  sheets=$($wb.Worksheets.Count)"
  $normal = $null
  foreach ($st in $wb.Styles) { if ($st.Name -eq 'Normal') { $normal = $st; break } }
  if ($normal) {
    "Normal style font: $($normal.Font.Name) $($normal.Font.Size)pt"
    if ($normal.Font.Name -ne 'Meiryo UI') { "NG: 標準スタイルが Meiryo UI ではない"; $problems++ }
  }
  foreach ($ws in $wb.Worksheets) {
    $used = $ws.UsedRange
    $lastRow = $used.Row + $used.Rows.Count - 1
    $ws.Activate()
    $win = $xl.ActiveWindow
    $fontsSeen = @{}
    $tiny = 0
    for ($r = 2; $r -le [Math]::Min($lastRow, 400); $r++) {
      $c = $ws.Cells.Item($r, 2)
      $t = [string]$c.Text
      if ($t.Length -gt 0) {
        $fontsSeen[$c.Font.Name] = 1
        if ($c.WrapText -and $ws.Rows.Item($r).RowHeight -lt 12) { $tiny++ }
      }
    }
    $fonts = ($fontsSeen.Keys | Sort-Object) -join ','
    "--- [{0}] used={1} rows={2} gridlines={3} zoom={4} fonts={5} B2='{6}'" -f $ws.Name, $used.Address(0, 0), $lastRow, $win.DisplayGridlines, $win.Zoom, $fonts, ([string]$ws.Cells.Item(2, 2).Text).Substring(0, [Math]::Min(40, ([string]$ws.Cells.Item(2, 2).Text).Length))
    if ($fonts -ne 'Meiryo UI') { "    NG: Meiryo UI 以外のフォント: $fonts"; $problems++ }
    if ($tiny -gt 0) { "    NG: 高さの足りない折り返し行 $tiny"; $problems++ }
  }
  $wb.ExportAsFixedFormat(0, $Pdf)
  "PDF    : $Pdf"
  if ($Capture) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $xl.WindowState = -4137
    $xl.ScreenUpdating = $true
    foreach ($name in ($Capture -split ',')) {
      $ws = $wb.Worksheets.Item($name.Trim())
      $ws.Activate()
      $used = $ws.UsedRange
      $last = [Math]::Min($used.Row + $used.Rows.Count - 1, 40)
      $rng = $ws.Range("A1:Z$last")
      $img = $null
      for ($try = 1; $try -le 4 -and $null -eq $img; $try++) {
        try {
          [System.Windows.Forms.Clipboard]::Clear()
          $rng.CopyPicture(1, 2)
          Start-Sleep -Milliseconds 600
          $img = [System.Windows.Forms.Clipboard]::GetImage()
        } catch { Start-Sleep -Milliseconds 800 }
      }
      if ($null -eq $img) { "WARN: 画像を取得できない（画面の確認は PDF で）: $name"; continue }
      $png = Join-Path $OutDir ("screen_" + $name.Trim() + ".png")
      $img.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
      "captured: $png ($($img.Width)x$($img.Height))"
    }
  }
  $wb.Close($false)
} finally {
  $xl.Quit()
  [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($xl)
}
$after = @(Get-ChildItem -Path $env:TEMP -Filter 'error*.xml' -ErrorAction SilentlyContinue | ForEach-Object FullName)
$new = @($after | Where-Object { $before -notcontains $_ })
if ($new.Count -gt 0) {
  "REPAIRED: Excel が修復ログを出力しました:"
  foreach ($f in $new) { "  $f"; Get-Content $f -Raw }
  exit 1
}
if ($problems -gt 0) { "RESULT : 問題 $problems 件"; exit 2 }
"RESULT : 修復なしで開け、全シート Meiryo UI・行の高さ OK"
