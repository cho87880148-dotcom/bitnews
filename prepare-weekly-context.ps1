# =========================================================
#  비트뉴스 — 주간 정리용 글감 준비
#
#  Claude Code 가 조사하기 좋게 이번 주 기사를 두 파일로 정리합니다.
#  data/articles.json 은 500건 넘고 1MB 가 넘어서 통째로 읽으면
#  맥락 창을 다 잡아먹습니다. 그래서 미리 걸러서 넘겨줍니다.
#
#    weekly/.work/index.md   한 줄 요약 목록 — 전체를 훑어보는 용도
#    weekly/.work/full.md    전문 요약 — 필요한 것만 찾아 읽는 용도
#    weekly/.work/topics.md  이번 주 화제 낱말 순위
#
#  .work 폴더는 .gitignore 에 있어 저장소에 올라가지 않습니다.
#
#  쓰는 법 : .\prepare-weekly-context.ps1 -Days 7
# =========================================================

param(
    [int]$Days = 7
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function ConvertTo-Utc {
    param([string]$Iso)
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
              [System.Globalization.DateTimeStyles]::AssumeUniversal
    return [datetime]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
}

$storePath = Join-Path (Join-Path $root 'data') 'articles.json'
if (-not (Test-Path $storePath)) { throw "data\articles.json 이 없습니다." }
$all = (Get-Content $storePath -Raw -Encoding UTF8) | ConvertFrom-Json

$nowUtc  = (Get-Date).ToUniversalTime()
$fromUtc = $nowUtc.AddDays(-$Days)
$week = @($all |
    Where-Object { (ConvertTo-Utc $_.published) -ge $fromUtc } |
    Sort-Object { (ConvertTo-Utc $_.published) } -Descending)

if ($week.Count -lt 10) { throw ("최근 {0}일 기사가 {1}건뿐입니다." -f $Days, $week.Count) }

$workDir = Join-Path (Join-Path $root 'weekly') '.work'
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$fromKst = $fromUtc.AddHours(9)
$toKst   = $nowUtc.AddHours(9)

# ---------------------------------------------------------
#  1) index.md — 전체를 한눈에 훑는 목록
# ---------------------------------------------------------
$idx = New-Object System.Text.StringBuilder
[void]$idx.AppendLine("# 이번 주 기사 목록 ($($fromKst.ToString('yyyy-MM-dd')) ~ $($toKst.ToString('yyyy-MM-dd')), $($week.Count)건)")
[void]$idx.AppendLine('')
[void]$idx.AppendLine('형식: `id | 날짜시각 | 매체 | 제목`')
[void]$idx.AppendLine('본문 요약은 full.md 에 있습니다. 필요한 기사만 grep 으로 찾아 읽으세요.')
[void]$idx.AppendLine('')
foreach ($a in $week) {
    $kst = (ConvertTo-Utc $a.published).AddHours(9)
    [void]$idx.AppendLine(('{0} | {1:MM-dd HH:mm} | {2} | {3}' -f $a.id, $kst, $a.source, $a.title))
}
[System.IO.File]::WriteAllText((Join-Path $workDir 'index.md'), $idx.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------
#  2) full.md — 전문 요약 (grep 해서 필요한 부분만 읽는 용도)
# ---------------------------------------------------------
$full = New-Object System.Text.StringBuilder
[void]$full.AppendLine("# 이번 주 기사 전문 요약 ($($week.Count)건)")
[void]$full.AppendLine('')
foreach ($a in $week) {
    $kst = (ConvertTo-Utc $a.published).AddHours(9)
    [void]$full.AppendLine(('## {0}' -f $a.title))
    [void]$full.AppendLine(('- id: {0}' -f $a.id))
    [void]$full.AppendLine(('- 매체: {0}' -f $a.source))
    [void]$full.AppendLine(('- 시각: {0:yyyy-MM-dd HH:mm} (한국시간)' -f $kst))
    [void]$full.AppendLine(('- 원문: {0}' -f $a.link))
    [void]$full.AppendLine('')
    [void]$full.AppendLine($a.summary)
    [void]$full.AppendLine('')
}
[System.IO.File]::WriteAllText((Join-Path $workDir 'full.md'), $full.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------
#  3) topics.md — 이번 주 화제 (제목 낱말 빈도)
# ---------------------------------------------------------
$stop = @(
    '비트코인','암호화폐','가상자산','시장','달러','기록','전망','분석','상승','하락','코인',
    '대비','기준','전날','오늘','지난','올해','가격','투자','거래','종목','관련','이번','현재',
    '이더리움','브리핑','시황','뉴스','업데이트','확인','발표','예정','가능','영향','상황'
)
$freq = @{}
foreach ($a in $week) {
    $words = @(($a.title -replace '[^0-9A-Za-z가-힣]', ' ') -split '\s+' | Select-Object -Unique)
    foreach ($w in $words) {
        if ($w.Length -lt 2) { continue }
        if ($stop -contains $w) { continue }
        if ($freq.ContainsKey($w)) { $freq[$w] = $freq[$w] + 1 } else { $freq[$w] = 1 }
    }
}
$top = @($freq.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 25)

$tp = New-Object System.Text.StringBuilder
[void]$tp.AppendLine('# 이번 주 화제 (제목에 많이 나온 낱말)')
[void]$tp.AppendLine('')
[void]$tp.AppendLine('숫자는 그 낱말이 제목에 나온 기사 수입니다. 여러 매체가 함께 다룬 주제일수록 큰 뉴스입니다.')
[void]$tp.AppendLine('다만 이건 기계적인 집계일 뿐이니, 실제로 중요한 주제인지는 기사를 읽고 판단하세요.')
[void]$tp.AppendLine('')
foreach ($t in $top) { [void]$tp.AppendLine(('- {0} : {1}건' -f $t.Key, $t.Value)) }
[System.IO.File]::WriteAllText((Join-Path $workDir 'topics.md'), $tp.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("  글감 준비 완료 — 기사 {0}건" -f $week.Count) -ForegroundColor Green
Write-Host ("  기간 : {0:yyyy-MM-dd} ~ {1:yyyy-MM-dd}" -f $fromKst, $toKst)
Write-Host ("  weekly\.work\index.md   {0:N0}자" -f $idx.Length)
Write-Host ("  weekly\.work\full.md    {0:N0}자" -f $full.Length)
Write-Host ("  weekly\.work\topics.md  상위 {0}개 낱말" -f $top.Count)
Write-Host ''
Write-Host '  이번 주 화제 상위 8개:'
foreach ($t in ($top | Select-Object -First 8)) { Write-Host ("    {0,-14} {1}건" -f $t.Key, $t.Value) }
Write-Host ''
