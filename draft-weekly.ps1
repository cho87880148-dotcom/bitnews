# =========================================================
#  비트뉴스 — 주간 정리 초안 만들기
#
#  하는 일:
#    모아둔 기사에서 지난 7일치를 꺼내
#    무엇이 이번 주 화제였는지 세어보고, 글 뼈대를 만들어 줍니다.
#
#  이 스크립트는 "재료 손질"까지만 합니다.
#  해석과 의견은 사람(또는 Claude)이 채워야 합니다. 그게 이 글의 존재 이유입니다.
#
#  쓰는 법:
#    .\draft-weekly.ps1                    지난 7일
#    .\draft-weekly.ps1 -Days 14           지난 14일
#    .\draft-weekly.ps1 -Slug 2026-08-w2   파일 이름 지정
#
#  실행하면 weekly\posts\<slug>.html 초안이 생기고,
#  weekly\weekly.json 에 넣을 목록 한 덩어리를 화면에 보여줍니다.
# =========================================================

param(
    [int]$Days = 7,
    [string]$Slug = '',
    [int]$TopN = 12
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function ConvertTo-Utc {
    param([string]$Iso)
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
              [System.Globalization.DateTimeStyles]::AssumeUniversal
    return [datetime]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
}
function Protect-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

$storePath = Join-Path (Join-Path $root 'data') 'articles.json'
if (-not (Test-Path $storePath)) { throw "data\articles.json 이 없습니다. 먼저 .\build.ps1 을 실행하세요." }
$all = (Get-Content $storePath -Raw -Encoding UTF8) | ConvertFrom-Json

$now = (Get-Date).ToUniversalTime()
$from = $now.AddDays(-$Days)
$week = @($all | Where-Object { (ConvertTo-Utc $_.published) -ge $from })

if ($week.Count -eq 0) { throw "최근 $Days 일 안에 기사가 없습니다." }

$fromKst = $from.AddHours(9)
$toKst   = $now.AddHours(9)
if (-not $Slug) {
    # 그 달의 몇 번째 주인지 대략 계산합니다
    $weekNo = [math]::Ceiling($toKst.Day / 7.0)
    $Slug = '{0:yyyy-MM}-w{1}' -f $toKst, $weekNo
}

Write-Host ''
Write-Host ("  주간 정리 초안 만들기") -ForegroundColor Yellow
Write-Host ("  기간   : {0:yyyy-MM-dd} ~ {1:yyyy-MM-dd} ({2}일)" -f $fromKst, $toKst, $Days)
Write-Host ("  기사   : {0}건" -f $week.Count)
Write-Host ("  파일   : weekly\posts\{0}.html" -f $Slug)
Write-Host ''

# ---------------------------------------------------------
#  이번 주 화제 세어보기
#  흔한 낱말은 빼야 "비트코인 172건" 같은 쓸모없는 결과가 안 나옵니다.
# ---------------------------------------------------------
$stop = @(
    '비트코인','암호화폐','가상자산','시장','달러','기록','전망','분석','상승','하락','코인',
    '대비','기준','전날','오늘','지난','올해','가격','투자','거래','종목','관련','이번','현재',
    '이더리움','브리핑','시세','뉴스','업데이트','확인','발표','예정','가능','영향','상황'
)
$freq = @{}
foreach ($x in $week) {
    $words = @(($x.title -replace '[^0-9A-Za-z가-힣]',' ') -split '\s+' | Select-Object -Unique)
    foreach ($w in $words) {
        if ($w.Length -lt 2) { continue }
        if ($stop -contains $w) { continue }
        if ($freq.ContainsKey($w)) { $freq[$w] = $freq[$w] + 1 } else { $freq[$w] = 1 }
    }
}
$topics = @($freq.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)

Write-Host "  이번 주 화제 (제목에 많이 나온 말)" -ForegroundColor Green
foreach ($t in $topics) { Write-Host ("    {0,-14} {1}건" -f $t.Key, $t.Value) }
Write-Host ''

# 화제별로 관련 기사를 묶어둡니다
$blocks = @()
foreach ($t in ($topics | Select-Object -First 4)) {
    $hits = @($week | Where-Object { $_.title -like ('*' + $t.Key + '*') } | Select-Object -First 4)
    if ($hits.Count -eq 0) { continue }
    $lines = ($hits | ForEach-Object {
        '          <li>{0} <em>({1}, {2:MM-dd})</em></li>' -f (Protect-Html $_.title), (Protect-Html $_.source), (ConvertTo-Utc $_.published).AddHours(9)
    }) -join "`n"
    $blocks += @"
      <section class="wk-sec">
        <h2>[채울 것] $($t.Key) — 무슨 일이 있었나</h2>
        <p>[여기에 해석을 씁니다. 사실 나열이 아니라 "그래서 이게 왜 중요한가"를 쓰세요.]</p>
        <!-- 참고한 기사 (글 쓰고 나면 이 주석은 지우세요)
        <ul>
$lines
        </ul>
        -->
      </section>
"@
}

# ---------------------------------------------------------
#  초안 파일 쓰기
# ---------------------------------------------------------
$body = @"
      <p class="wk-lead">
        [도입부 — 이번 주를 한 문단으로. 숫자 하나와 "왜"를 넣으면 좋습니다.]
      </p>

      <div class="wk-summary">
        <h2>이번 주 세 줄 요약</h2>
        <ul>
          <li>[첫째]</li>
          <li>[둘째]</li>
          <li>[셋째]</li>
        </ul>
      </div>

$($blocks -join "`n`n")

      <section class="wk-sec">
        <h2>다음 주에 볼 것</h2>
        <ul class="wk-list">
          <li><strong>[관전 포인트 1]</strong> — [왜 봐야 하는지]</li>
          <li><strong>[관전 포인트 2]</strong> — [왜 봐야 하는지]</li>
        </ul>
      </section>

      <div class="wk-disclaimer">
        <p>
          이 글은 한 주간 보도된 내용을 정리한 것으로, <strong>투자 권유가 아닙니다.</strong>
          가상자산은 가격 변동성이 크고 원금 손실 가능성이 있습니다.
          수치는 각 매체가 보도한 시점 기준이며 실시간 시세와 다를 수 있습니다.
          투자 판단과 그 결과에 대한 책임은 본인에게 있습니다.
        </p>
      </div>
"@

$postsDir = Join-Path (Join-Path $root 'weekly') 'posts'
if (-not (Test-Path $postsDir)) { New-Item -ItemType Directory -Force -Path $postsDir | Out-Null }
$dest = Join-Path $postsDir ($Slug + '.html')

if (Test-Path $dest) {
    Write-Host ("  이미 있는 파일이라 덮어쓰지 않았습니다: {0}" -f $dest) -ForegroundColor DarkYellow
    Write-Host '  다시 만들려면 그 파일을 지우고 실행하세요.'
} else {
    [System.IO.File]::WriteAllText($dest, $body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("  초안 만듦: weekly\posts\{0}.html" -f $Slug) -ForegroundColor Green
}

Write-Host ''
Write-Host '  ---- weekly.json 의 posts 맨 위에 넣을 내용 ----' -ForegroundColor Green
Write-Host @"
    {
      "slug": "$Slug",
      "title": "[핵심 사건을 앞에 — 주차는 뒤에]",
      "subtitle": "$($toKst.ToString('yyyy년 M월')) 비트코인 정리 ($($fromKst.ToString('M월 d일')) ~ $($toKst.ToString('M월 d일')))",
      "desc": "[검색 결과에 나올 설명. 155자 안쪽.]",
      "from": "$($fromKst.ToString('yyyy-MM-dd'))",
      "to": "$($toKst.ToString('yyyy-MM-dd'))",
      "published": "$($toKst.ToString('yyyy-MM-dd'))"
    },
"@
Write-Host ''
Write-Host '  다 쓰고 나면 .\build.ps1 을 실행하세요.' -ForegroundColor Green
Write-Host ''
