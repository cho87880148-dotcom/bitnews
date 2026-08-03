# =========================================================
#  비트뉴스 — 과거 기사 채우기 (한 번만 실행하는 스크립트)
#
#  왜 따로 있나?
#   RSS 는 최신 기사 몇십 건만 줍니다. 과거 기사는 못 가져옵니다.
#   블록미디어는 워드프레스로 만들어져 있어서 공개 API 로 날짜를 지정해
#   지난 기사를 받아올 수 있습니다. 그걸 쓰는 스크립트입니다.
#
#  build.ps1 에 넣지 않은 이유:
#   과거 기사는 한 번만 채우면 됩니다. 1시간마다 도는 build.ps1 이
#   매번 8개월치를 다시 받아오면 쓸데없이 느리고 상대 서버에도 부담입니다.
#
#  쓰는 법:
#    .\backfill.ps1                     올해 1월부터 월 60건씩
#    .\backfill.ps1 -PerMonth 100       월 100건씩
#    .\backfill.ps1 -From 2025-06-01    작년 6월부터
#    .\backfill.ps1 -DryRun             실제로 저장하지 않고 몇 건인지만 확인
#
#  실행 후에는 반드시 .\build.ps1 을 한 번 돌려야 페이지가 만들어집니다.
#
#  ※ 토큰포스트는 과거 기사를 주는 통로가 없어서 (RSS 2페이지가 1페이지와
#     똑같음) 여기서는 블록미디어만 가져옵니다.
# =========================================================

param(
    [datetime]$From = '2026-01-01',   # 언제부터 채울지
    [int]$PerMonth = 60,              # 한 달에 몇 건씩 (고르게 뽑습니다)
    [switch]$DryRun                   # 붙이면 저장하지 않고 건수만 보여줍니다
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$root      = $PSScriptRoot
$dataDir   = Join-Path $root 'data'
$storePath = Join-Path $dataDir 'articles.json'
$apiBase   = 'https://www.blockmedia.co.kr/wp-json/wp/v2'
$sourceName = '블록미디어'
$sourceSite = 'https://www.blockmedia.co.kr'

# ---------------------------------------------------------
#  도우미 (build.ps1 과 같은 규칙을 써야 기사가 중복되지 않습니다)
# ---------------------------------------------------------
function Get-Api {
    param([string]$Url)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'Mozilla/5.0 (compatible; BitNewsBot/1.0)'
    $req.Timeout = 40000
    $res = $req.GetResponse()
    try {
        $sr = New-Object System.IO.StreamReader($res.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd()
        $sr.Close()
    } finally { $res.Close() }
    if ([string]::IsNullOrWhiteSpace($t)) { return @() }
    return ($t | ConvertFrom-Json)
}

function ConvertTo-PlainText {
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $t = $Html -replace '(?is)<script.*?</script>', ''
    $t = $t -replace '(?is)<style.*?</style>', ''
    $t = $t -replace '(?s)<[^>]+>', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace '\[&hellip;\]|\[…\]', ''
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

function Limit-Text {
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    $cut = $Text.Substring(0, $Max)
    $sp = $cut.LastIndexOf(' ')
    if ($sp -gt ($Max * 0.6)) { $cut = $cut.Substring(0, $sp) }
    return $cut.TrimEnd() + '…'
}

# build.ps1 과 똑같은 방식이어야 같은 기사에 같은 번호가 붙습니다
function Get-ArticleId {
    param([string]$Link)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Link))
    $sha.Dispose()
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0, 10)
}

# ---------------------------------------------------------
#  설정과 기존 기사 읽기
# ---------------------------------------------------------
$cfg = (Get-Content (Join-Path $root 'sources.json') -Raw -Encoding UTF8) | ConvertFrom-Json
$keywords = @($cfg.keywords)

if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

$store = @{}
if (Test-Path $storePath) {
    $old = (Get-Content $storePath -Raw -Encoding UTF8) | ConvertFrom-Json
    foreach ($a in @($old)) { if ($a.link) { $store[$a.link] = $a } }
}

Write-Host ''
Write-Host '  과거 기사 채우기' -ForegroundColor Yellow
Write-Host ("  기간     : {0:yyyy-MM-dd} ~ 오늘" -f $From)
Write-Host ("  목표     : 한 달에 최대 {0}건" -f $PerMonth)
Write-Host ("  기존 보관: {0}건" -f $store.Count)
if ($DryRun) { Write-Host '  (연습 모드 — 저장하지 않습니다)' -ForegroundColor DarkYellow }
Write-Host ''

# 카테고리 번호를 이름으로 바꿀 표를 미리 받아둡니다
$catMap = @{}
try {
    foreach ($c in (Get-Api "$apiBase/categories?per_page=100&_fields=id,name")) {
        $catMap[[string]$c.id] = $c.name
    }
} catch {
    Write-Host '  (카테고리 이름표를 받지 못해 태그 없이 진행합니다)' -ForegroundColor DarkYellow
}

# ---------------------------------------------------------
#  달마다 돌면서 기사를 모읍니다
# ---------------------------------------------------------
$collected = New-Object System.Collections.ArrayList
$monthStart = Get-Date -Year $From.Year -Month $From.Month -Day 1 -Hour 0 -Minute 0 -Second 0
$today = Get-Date

while ($monthStart -lt $today) {
    $monthEnd = $monthStart.AddMonths(1)
    $after  = $monthStart.ToString('yyyy-MM-ddTHH:mm:ss')
    $before = $monthEnd.ToString('yyyy-MM-ddTHH:mm:ss')

    # 이 달의 후보 기사를 모읍니다 (최대 5페이지 = 500건까지 훑습니다)
    $matched = New-Object System.Collections.ArrayList
    for ($page = 1; $page -le 5; $page++) {
        $url = "$apiBase/posts?after=$after&before=$before&per_page=100&page=$page&orderby=date&order=desc&_fields=date_gmt,link,title,excerpt,categories,featured_media"
        try {
            $posts = @(Get-Api $url)
        } catch {
            break   # 페이지가 더 없으면 API 가 오류를 냅니다. 정상 종료로 봅니다.
        }
        if ($posts.Count -eq 0) { break }

        foreach ($p in $posts) {
            $title = ConvertTo-PlainText $p.title.rendered
            $desc  = ConvertTo-PlainText $p.excerpt.rendered
            if (-not $title -or -not $p.link) { continue }

            # build.ps1 과 같은 키워드로 비트코인 관련 기사만 남깁니다
            if ($keywords.Count -gt 0) {
                $hay = "$title $desc"
                $hit = $false
                foreach ($k in $keywords) {
                    if ($hay.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
                }
                if (-not $hit) { continue }
            }

            if ($store.ContainsKey($p.link)) { continue }   # 이미 있는 기사
            [void]$matched.Add([pscustomobject]@{
                post    = $p
                title   = $title
                summary = Limit-Text $desc 400
            })
        }
        if ($posts.Count -lt 100) { break }
    }

    # 한 달 안에서 고르게 뽑습니다 (앞쪽에만 몰리지 않도록 일정 간격으로)
    $pick = @()
    if ($matched.Count -le $PerMonth) {
        $pick = @($matched)
    } else {
        $step = $matched.Count / [double]$PerMonth
        for ($i = 0; $i -lt $PerMonth; $i++) {
            $pick += $matched[[int][math]::Floor($i * $step)]
        }
    }

    # 뽑은 기사들의 대표 이미지를 한 번에 조회합니다 (한 건씩 부르면 너무 느립니다)
    $imgMap = @{}
    $mediaIds = @($pick | Where-Object { $_.post.featured_media -gt 0 } |
                  ForEach-Object { $_.post.featured_media } | Select-Object -Unique)
    for ($s = 0; $s -lt $mediaIds.Count; $s += 80) {
        $chunk = $mediaIds[$s..([math]::Min($s + 79, $mediaIds.Count - 1))]
        try {
            foreach ($m in (Get-Api ("$apiBase/media?include={0}&per_page=100&_fields=id,source_url" -f ($chunk -join ',')))) {
                $imgMap[[string]$m.id] = $m.source_url
            }
        } catch { }   # 이미지를 못 받아도 기사는 살립니다
    }

    foreach ($item in $pick) {
        $p = $item.post
        $img = ''
        if ($p.featured_media -gt 0 -and $imgMap.ContainsKey([string]$p.featured_media)) {
            $img = $imgMap[[string]$p.featured_media]
        }
        $cats = @()
        foreach ($cid in @($p.categories)) {
            if ($catMap.ContainsKey([string]$cid)) { $cats += $catMap[[string]$cid] }
        }

        # date_gmt 는 UTC 인데 뒤에 Z 가 없어서 붙여줍니다
        $pubIso = ([datetime]::Parse($p.date_gmt + 'Z', [System.Globalization.CultureInfo]::InvariantCulture,
                   [System.Globalization.DateTimeStyles]::AdjustToUniversal)).ToString('o')

        [void]$collected.Add([pscustomobject]@{
            id         = Get-ArticleId $p.link
            title      = $item.title
            link       = $p.link
            source     = $sourceName
            sourceSite = $sourceSite
            author     = ''
            published  = $pubIso
            summary    = $item.summary
            image      = $img
            categories = @($cats | Select-Object -Unique -First 6)
        })
    }

    Write-Host ("  {0:yyyy년 M월}  후보 {1,4}건 중 {2,3}건 확보" -f $monthStart, $matched.Count, $pick.Count)
    $monthStart = $monthEnd
}

# ---------------------------------------------------------
#  저장
# ---------------------------------------------------------
Write-Host ''
if ($collected.Count -eq 0) {
    Write-Host '  새로 채울 기사가 없습니다. (이미 다 가지고 있습니다)' -ForegroundColor DarkYellow
    return
}

if ($DryRun) {
    Write-Host ("  연습 모드 — {0}건을 가져올 수 있습니다. 저장하지 않았습니다." -f $collected.Count) -ForegroundColor Yellow
    Write-Host '  실제로 채우려면 -DryRun 을 빼고 다시 실행하세요.'
    return
}

foreach ($a in $collected) { $store[$a.link] = $a }

$final = @($store.Values | Sort-Object {
    [datetime]::Parse($_.published, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
        [System.Globalization.DateTimeStyles]::AssumeUniversal)
} -Descending)

$json = $final |
    Select-Object id, title, link, source, sourceSite, author, published, summary, image, categories |
    ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($storePath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("  새로 채운 기사 : {0}건" -f $collected.Count) -ForegroundColor Green
Write-Host ("  전체 보관 기사 : {0}건" -f $final.Count) -ForegroundColor Green
Write-Host ''
Write-Host '  이제 .\build.ps1 을 실행하면 페이지가 만들어집니다.' -ForegroundColor Green
Write-Host ''
