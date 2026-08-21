# =========================================================
#  비트뉴스 — 뉴스 수집 및 사이트 생성
#
#  하는 일 (위에서 아래로 순서대로):
#    1. sources.json 에 적힌 언론사 RSS 를 하나씩 읽어옵니다
#    2. 비트코인과 관련 없는 기사를 걸러냅니다
#    3. 예전에 모아둔 data/articles.json 과 합칩니다 (중복 제거)
#    4. "지금 뜨는 정도"(인기 점수)를 매깁니다
#    5. dist 폴더에 HTML 을 전부 새로 만들어 냅니다
#
#  쓰는 법 : .\build.ps1
#  미리보기 : .\build.ps1  실행 후  .\serve.ps1
#
#  주의: dist 폴더는 매번 새로 만들어집니다. 여기 있는 파일을 직접 고치면
#        다음 실행 때 사라집니다. 디자인은 assets\ 와 templates\ 를 고치세요.
# =========================================================

param(
    [string]$OutDir = 'dist',
    [int]$PerPage = 12,      # 한 페이지에 보여줄 기사 수
    [int]$KeepMax = 2000     # 보관할 최대 기사 수 (오래된 것부터 버립니다)
                             # ★ 이 숫자를 함부로 내리지 말 것. 하루 65~166건이 쌓이므로
                             #   480 으로 내리면 4일치만 남아 주간 정리(-Days 7)가 깨진다.
                             #   2026-08-12 에 480 으로 내렸다가 이 이유로 되돌렸다.
                             # 주간 정리가 링크한 기사는 이 상한을 넘겨도 보존합니다(4번 항목).
)

$ErrorActionPreference = 'Stop'

# 옛 방식(TLS 1.0)만 쓰면 요즘 사이트는 연결을 거부합니다
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$root    = $PSScriptRoot
$dataDir = Join-Path $root 'data'
$outPath = Join-Path $root $OutDir

# =========================================================
#  도우미 함수들
# =========================================================

# RSS 를 받아 XML 로 바꿉니다.
# PowerShell 5.1 의 Invoke-WebRequest 는 한글을 자동으로 못 알아보고 깨뜨리기 때문에
# 직접 UTF-8 로 읽도록 지정했습니다. (토큰포스트에서 실제로 겪은 문제입니다)
function Get-FeedXml {
    param([string]$Url)

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'Mozilla/5.0 (compatible; BitNewsBot/1.0)'
    $req.Timeout = 20000
    $req.AllowAutoRedirect = $true

    $res = $req.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader($res.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Close()
    } finally {
        $res.Close()
    }
    return [xml]$text
}

# XML 안에서 이름이 정확히 일치하는 자식 하나를 찾습니다.
# media:content 와 content:encoded 처럼 이름이 비슷한 것들이 섞여 있어서
# PowerShell 의 기본 방식($item.content)으로는 엉뚱한 것이 잡힙니다.
function Get-Child {
    param($Node, [string]$Name)
    foreach ($c in $Node.ChildNodes) { if ($c.Name -eq $Name) { return $c } }
    return $null
}
function Get-ChildText {
    param($Node, [string]$Name)
    $c = Get-Child $Node $Name
    if ($null -ne $c) { return $c.InnerText }
    return ''
}
function Get-ChildAttr {
    param($Node, [string]$Name, [string]$Attr)
    $c = Get-Child $Node $Name
    if ($null -ne $c) { return [string]$c.GetAttribute($Attr) }
    return ''
}

# HTML 태그를 걷어내고 &amp; 같은 기호를 원래 글자로 되돌린 뒤,
# 줄바꿈과 연속 공백을 하나로 정리합니다.
function ConvertTo-PlainText {
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }

    $t = $Html -replace '(?is)<script.*?</script>', ''
    $t = $t -replace '(?is)<style.*?</style>', ''
    $t = $t -replace '(?s)<[^>]+>', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

# 글자 수를 넘기면 뒤를 자르고 … 를 붙입니다
function Limit-Text {
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    $cut = $Text.Substring(0, $Max)
    $sp = $cut.LastIndexOf(' ')
    if ($sp -gt ($Max * 0.6)) { $cut = $cut.Substring(0, $sp) }
    return $cut.TrimEnd() + '…'
}

# HTML 에 글자를 넣을 때 태그로 오해받지 않게 기호를 바꿉니다.
# 이걸 빼먹으면 제목에 < 가 들어간 기사 하나 때문에 페이지가 통째로 깨집니다.
function Protect-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

# 기사 주소로 고유하고 항상 똑같은 번호를 만듭니다.
# 같은 기사가 다시 수집돼도 같은 파일 이름이 나와야 주소가 바뀌지 않습니다.
function Get-ArticleId {
    param([string]$Link)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Link))
    $sha.Dispose()
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0, 10)
}

# RSS 의 날짜 표기(Mon, 03 Aug 2026 03:10:34 +0000)를 UTC 날짜 값으로 바꿉니다.
function ConvertTo-DateTime {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return (Get-Date).ToUniversalTime() }
    try {
        return [datetime]::Parse($Raw, [System.Globalization.CultureInfo]::InvariantCulture,
               [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch {
        return (Get-Date).ToUniversalTime()
    }
}

# 보관해둔 날짜 글자(2026-08-03T04:08:33Z)를 다시 날짜 값으로 되돌립니다.
# 그냥 [datetime]"...Z" 로 바꾸면 PowerShell 이 한국 시각으로 바꿔버려서
# 나중에 UTC 와 빼면 9시간이 어긋나 모든 기사가 "방금"으로 표시됩니다.
function ConvertTo-Utc {
    param([string]$Iso)
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
              [System.Globalization.DateTimeStyles]::AssumeUniversal
    return [datetime]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
}

# 한국 시각으로 "8월 3일 12:10" 처럼 보여줍니다
function Format-Kst {
    param([datetime]$Utc)
    $kst = $Utc.AddHours(9)
    return ('{0}월 {1}일 {2:00}:{3:00}' -f $kst.Month, $kst.Day, $kst.Hour, $kst.Minute)
}

# "3시간 전" 처럼 보여줍니다 (하루가 넘으면 날짜로)
function Format-Ago {
    param([datetime]$Utc)
    $diff = (Get-Date).ToUniversalTime() - $Utc
    if ($diff.TotalMinutes -lt 1)  { return '방금' }
    if ($diff.TotalMinutes -lt 60) { return ('{0}분 전' -f [int]$diff.TotalMinutes) }
    if ($diff.TotalHours   -lt 24) { return ('{0}시간 전' -f [int]$diff.TotalHours) }
    if ($diff.TotalDays    -lt 7)  { return ('{0}일 전' -f [int]$diff.TotalDays) }
    return (Format-Kst $Utc)
}

# 기사에서 대표 이미지 주소를 찾습니다. 언론사마다 넣는 자리가 달라서 차례로 뒤집니다.
function Get-ImageUrl {
    param($Item)

    foreach ($tag in @('media:content', 'media:thumbnail', 'enclosure')) {
        $u = Get-ChildAttr $Item $tag 'url'
        if ($u) { return $u }
    }
    # 위에 없으면 본문 안의 첫 번째 <img src="..."> 를 씁니다
    $body = (Get-ChildText $Item 'content:encoded') + (Get-ChildText $Item 'description')
    $m = [regex]::Match($body, '<img[^>]+src\s*=\s*["'']([^"'']+)["'']', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# ---------------------------------------------------------
#  인기 점수용 — 제목에서 의미 있는 낱말만 뽑습니다
#
#  진짜 조회수는 방문자 통계가 있어야 알 수 있고 지금은 없습니다.
#  대신 실제로 알 수 있는 것으로 "지금 뜨는 정도"를 매깁니다:
#    1) 여러 기사가 같은 주제를 다루고 있는가 (겹칠수록 큰 뉴스)
#    2) 얼마나 최근 기사인가
#  나중에 방문자 통계를 붙이면 이 부분만 바꾸면 됩니다.
# ---------------------------------------------------------
$script:StopWords = @(
    '그리고','하지만','이번','대해','통해','위해','에서','으로','까지','부터','보다','같은',
    '있다','없다','했다','한다','된다','됐다','올해','지난','오늘','내일','기자',
    '뉴스','전망','분석','시황','속보','단독','종합','예상','가능','기록',
    'the','and','for','with','you','are','this','that','from','has','will','its'
)
function Get-Tokens {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return @() }
    # 한글·영문·숫자만 남기고 나머지는 공백으로 바꿉니다
    $clean = $Title -replace '[^0-9A-Za-z가-힣]', ' '
    $out = New-Object System.Collections.ArrayList
    foreach ($w in ($clean -split '\s+')) {
        if ($w.Length -lt 2) { continue }
        if ($script:StopWords -contains $w.ToLower()) { continue }
        [void]$out.Add($w)
    }
    return $out.ToArray()
}

# =========================================================
#  1. 설정 읽기
# =========================================================
$cfgPath = Join-Path $root 'sources.json'
if (-not (Test-Path $cfgPath)) { throw "sources.json 이 없습니다: $cfgPath" }
$cfg = (Get-Content $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json

$siteName = $cfg.site.name
$baseUrl  = ($cfg.site.baseUrl -replace '/+$', '')   # 끝의 / 는 떼어냅니다
$keywords = @($cfg.keywords)

# ---------------------------------------------------------
#  첫 화면에만 다른 상호와 사업자 정보를 보여주는 장치입니다 — 지금은 꺼져 있습니다.
#
#  2026-08-06 광고 승인용으로 'Novacent' 를 켰다가 2026-08-21 에 껐습니다.
#  두 줄이 빈 문자열이면 첫 화면도 sources.json 의 상호("비트뉴스")를 쓰고
#  사업자 정보 줄은 아예 나오지 않습니다. 지금 상태가 정상입니다.
#
#  ▶ 다시 켜려면 아래 두 줄에 값을 넣고 .\build.ps1 실행.
#    $tempHomeBrand   = 'Novacent'
#    $tempHomeBizInfo = 'Company : ... | CEO : ... | Business Registration Number : ...'
#    적용 범위는 dist\index.html **한 장뿐**입니다. 기사·목록 2쪽 이후·가이드·주간정리와
#    og:site_name, RSS 제목, 구조화 데이터 발행처 이름은 늘 "비트뉴스" 입니다.
#    (templates\base.html 이나 이 아래 코드는 손댈 필요 없습니다)
# ---------------------------------------------------------
$tempHomeBrand   = ''
$tempHomeBizInfo = ''

Write-Host ''
Write-Host "  $siteName 사이트 생성 시작" -ForegroundColor Yellow
Write-Host ''

# =========================================================
#  2. 예전에 모아둔 기사 불러오기
# =========================================================
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$storePath = Join-Path $dataDir 'articles.json'

$store = @{}   # 열쇠는 기사 주소, 값은 기사 정보
if (Test-Path $storePath) {
    $old = (Get-Content $storePath -Raw -Encoding UTF8) | ConvertFrom-Json
    foreach ($a in @($old)) {
        if ($a.link) { $store[$a.link] = $a }
    }
    Write-Host ("  보관 중인 기사 {0}건을 불러왔습니다" -f $store.Count)
}

# =========================================================
#  3. RSS 수집
# =========================================================
$newCount = 0

foreach ($src in $cfg.sources) {
    if (-not $src.enabled) { continue }

    try {
        $xml = Get-FeedXml $src.url
    } catch {
        # 한 곳이 죽어도 나머지는 계속 모아야 합니다
        Write-Host ("  건너뜀  {0,-14} 연결 실패: {1}" -f $src.name, $_.Exception.Message) -ForegroundColor DarkYellow
        continue
    }

    $items = @($xml.rss.channel.item)
    $added = 0
    $skipped = 0

    foreach ($item in $items) {
        $title = ConvertTo-PlainText (Get-ChildText $item 'title')
        $link  = (Get-ChildText $item 'link').Trim()
        if (-not $title -or -not $link) { continue }

        $desc = ConvertTo-PlainText (Get-ChildText $item 'description')

        # 비트코인과 관련된 기사만 남깁니다 (keywords 가 비어 있으면 전부 통과)
        if ($keywords.Count -gt 0) {
            $haystack = "$title $desc"
            $hit = $false
            foreach ($k in $keywords) {
                if ($haystack.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
            }
            if (-not $hit) { $skipped++; continue }
        }

        # 이미 있는 기사는 다시 담지 않습니다
        if ($store.ContainsKey($link)) { continue }

        $published = ConvertTo-DateTime (Get-ChildText $item 'pubDate')

        # 카테고리는 여러 개일 수 있어 전부 모읍니다
        $cats = @()
        foreach ($c in $item.ChildNodes) {
            if ($c.Name -eq 'category') {
                $v = ConvertTo-PlainText $c.InnerText
                if ($v) { $cats += $v }
            }
        }

        $store[$link] = [pscustomobject]@{
            id         = Get-ArticleId $link
            title      = $title
            link       = $link
            source     = $src.name
            sourceSite = $src.site
            author     = ConvertTo-PlainText (Get-ChildText $item 'dc:creator')
            published  = $published.ToString('o')
            summary    = Limit-Text $desc 400
            image      = Get-ImageUrl $item
            categories = @($cats | Select-Object -Unique -First 6)
        }
        $added++
        $newCount++
    }

    Write-Host ("  가져옴  {0,-14} 새 기사 {1,3}건  (관련 없어 제외 {2}건)" -f $src.name, $added, $skipped)
}

if ($store.Count -eq 0) {
    throw "기사를 하나도 모으지 못했습니다. 인터넷 연결이나 sources.json 의 주소를 확인하세요."
}

# =========================================================
#  4. 최신순 정렬 · 오래된 것 버리기 · 보관
# =========================================================
# 주간 정리 글이 근거로 링크한 기사는 오래돼도 버리지 않습니다.
# 버리면 그 링크가 404 가 되는데, 주간 정리는 우리가 직접 쓴 글이라 가장 아깝습니다.
$pinned = @{}
$postsDir = Join-Path (Join-Path $root 'weekly') 'posts'
if (Test-Path $postsDir) {
    foreach ($f in (Get-ChildItem -Path $postsDir -Filter '*.html')) {
        $html = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        foreach ($m in [regex]::Matches($html, '\.\./news/([0-9a-f]+)\.html')) {
            $pinned[$m.Groups[1].Value] = $true
        }
    }
}

$sorted   = @($store.Values | Sort-Object { (ConvertTo-Utc $_.published) } -Descending)
$articles = @($sorted | Select-Object -First $KeepMax)

$keptIds = @{}
foreach ($a in $articles) { $keptIds[$a.id] = $true }
$rescued = @($sorted | Where-Object { $pinned[$_.id] -and -not $keptIds[$_.id] })
if ($rescued.Count -gt 0) {
    $articles = @($articles) + @($rescued)
    Write-Host ("  주간 정리가 링크한 기사 {0}건은 상한을 넘겨도 보존했습니다" -f $rescued.Count) -ForegroundColor DarkCyan
}

Write-Host ''
Write-Host ("  새로 추가 {0}건 / 전체 보관 {1}건" -f $newCount, $articles.Count) -ForegroundColor Green

# 다음 실행 때 이어 쓰도록 저장합니다. 이게 있어야 예전 기사 페이지가 사라지지 않습니다.
# 인기 점수는 매번 새로 계산하므로 저장하지 않습니다.
$json = $articles |
    Select-Object id, title, link, source, sourceSite, author, published, summary, image, categories |
    ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($storePath, $json, (New-Object System.Text.UTF8Encoding($false)))

# =========================================================
#  5. 인기 점수 매기기
# =========================================================

# 모든 제목의 낱말을 세어, 어떤 주제가 여러 기사에 걸쳐 나오는지 봅니다
$freq = @{}
$tokenMap = @{}
foreach ($a in $articles) {
    $t = @(Get-Tokens $a.title | Select-Object -Unique)
    $tokenMap[$a.id] = $t
    foreach ($w in $t) {
        if ($freq.ContainsKey($w)) { $freq[$w] = $freq[$w] + 1 } else { $freq[$w] = 1 }
    }
}

$nowUtc = (Get-Date).ToUniversalTime()
foreach ($a in $articles) {
    # 1) 주제 겹침 — 다른 기사도 같은 낱말을 쓸수록 점수가 올라갑니다 (최대 40점)
    $topic = 0
    foreach ($w in $tokenMap[$a.id]) { $topic += ($freq[$w] - 1) }
    if ($topic -gt 40) { $topic = 40 }

    # 2) 최신성 — 48시간이 지나면 0점이 됩니다 (최대 40점)
    $hours = ($nowUtc - (ConvertTo-Utc $a.published)).TotalHours
    $fresh = [math]::Max(0, 48 - $hours) / 48 * 40

    # 3) 사진이 있으면 목록에서 눈에 띄므로 약간 가산
    $img = 0
    if ($a.image) { $img = 5 }

    $a | Add-Member -NotePropertyName hot -NotePropertyValue ([math]::Round($topic + $fresh + $img, 2)) -Force
}

$byHot  = @($articles | Sort-Object hot -Descending)
$weekly = @($articles |
    Where-Object { ($nowUtc - (ConvertTo-Utc $_.published)).TotalDays -le 7 } |
    Sort-Object hot -Descending)

Write-Host ("  인기 순위 계산 완료 — 1위: {0}" -f (Limit-Text $byHot[0].title 34))

# =========================================================
#  6. dist 폴더 새로 만들기
# =========================================================
if (Test-Path $outPath) { Remove-Item $outPath -Recurse -Force }
New-Item -ItemType Directory -Path $outPath | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outPath 'news') | Out-Null

# assets 폴더를 그대로 복사합니다
Copy-Item (Join-Path $root 'assets') -Destination (Join-Path $outPath 'assets') -Recurse -Force

# Join-Path 는 PowerShell 5.1 에서 한 번에 두 개까지만 이어붙일 수 있어 두 번 나눠 씁니다
$templatePath = Join-Path (Join-Path $root 'templates') 'base.html'
$template = Get-Content $templatePath -Raw -Encoding UTF8

$updatedLabel = Format-Kst $nowUtc

# ---------------------------------------------------------
#  상단 속보 띠 — 왼쪽으로 흘러가는 전광판
#
#  같은 목록을 두 번 이어붙입니다. CSS 가 절반 지점까지 민 뒤 처음으로
#  되돌아가는데, 뒤쪽 절반이 앞쪽과 똑같아서 끊김 없이 계속 도는 것처럼 보입니다.
# ---------------------------------------------------------
function New-TickerHtml {
    param($List, [string]$BasePrefix = '')

    $one = ($List | ForEach-Object {
        if ($_.image) {
            $thumb = '<img src="{0}" alt="" loading="lazy" />' -f (Protect-Html $_.image)
        } else {
            $thumb = '<span class="ticker-thumb-empty">₿</span>'
        }
        '<a class="ticker-item" href="{0}news/{1}.html">{2}<span>{3}</span></a>' -f `
            $BasePrefix, $_.id, $thumb, (Protect-Html (Limit-Text $_.title 40))
    }) -join "`n          "

    return @"
  <div class="ticker">
    <div class="container ticker-inner">
      <div class="ticker-label"><span class="ticker-dot"></span>속보</div>
      <div class="ticker-viewport">
        <div class="ticker-track">
          $one
          $one
        </div>
      </div>
    </div>
  </div>
"@
}

# ---------------------------------------------------------
#  가운데 큰 슬라이드 (주요 뉴스)
# ---------------------------------------------------------
function New-SlideHtml {
    param($List)

    $slides = ($List | ForEach-Object {
        if ($_.image) {
            $bg = '<img class="slide-img" src="{0}" alt="" />' -f (Protect-Html $_.image)
        } else {
            $bg = '<div class="slide-img slide-img-empty">₿</div>'
        }
        @"
<a class="slide" href="news/$($_.id).html">
            $bg
            <div class="slide-text">
              <span class="source-badge">$(Protect-Html $_.source)</span>
              <h3>$(Protect-Html (Limit-Text $_.title 60))</h3>
              <p class="slide-meta">$(Format-Ago (ConvertTo-Utc $_.published))</p>
            </div>
          </a>
"@
    }) -join "`n          "

    $dots = ''
    for ($i = 0; $i -lt @($List).Count; $i++) {
        if ($i -eq 0) { $cls = ' class="is-active"' } else { $cls = '' }
        $dots += ('<button data-dot="{0}"{1} aria-label="{2}번째 기사"></button>' -f $i, $cls, ($i + 1))
    }

    return @"
        <div class="slider" data-slider>
          <div class="slides">
          $slides
          </div>
          <div class="slider-dots">$dots</div>
        </div>
"@
}

# ---------------------------------------------------------
#  왼쪽 탭 목록 / 오른쪽 트렌딩 목록에 쓰는 작은 항목
# ---------------------------------------------------------
function New-MiniItem {
    param($A, [int]$Rank = 0)

    if ($A.image) {
        $thumb = '<img src="{0}" alt="" loading="lazy" />' -f (Protect-Html $A.image)
    } else {
        $thumb = '<span class="mini-thumb-empty">₿</span>'
    }

    $badge = ''
    if ($Rank -gt 0) { $badge = '<span class="rank-badge">{0}</span>' -f $Rank }

    return @"
<li>
            <a href="news/$($A.id).html">
              <span class="mini-thumb">$thumb$badge</span>
              <span class="mini-body">
                <span class="mini-title">$(Protect-Html (Limit-Text $A.title 55))</span>
                <span class="mini-meta">$(Protect-Html $A.source) · $(Format-Ago (ConvertTo-Utc $A.published))</span>
              </span>
            </a>
          </li>
"@
}

# ---------------------------------------------------------
#  맨 위 특집 구역 (왼쪽 탭 + 가운데 슬라이드 + 오른쪽 트렌딩)
# ---------------------------------------------------------
function New-FeaturedHtml {
    $latestList  = @($articles | Select-Object -First 4)
    $popularList = @($byHot | Select-Object -First 4)
    $weekList    = @($weekly | Select-Object -First 4)
    if ($weekList.Count -eq 0) { $weekList = $popularList }

    $slideList = @($byHot | Where-Object { $_.image } | Select-Object -First 6)
    if ($slideList.Count -eq 0) { $slideList = @($byHot | Select-Object -First 3) }

    $trendList = @($byHot | Select-Object -First 8)

    $latestHtml  = ($latestList  | ForEach-Object { New-MiniItem $_ }) -join "`n          "
    $popularHtml = ($popularList | ForEach-Object { New-MiniItem $_ }) -join "`n          "
    $weekHtml    = ($weekList    | ForEach-Object { New-MiniItem $_ }) -join "`n          "

    $rank = 0
    $trendHtml = ($trendList | ForEach-Object { $rank++; New-MiniItem $_ $rank }) -join "`n          "

    return @"
    <section class="featured">

      <div class="col col-left">
        <div class="tabs">
          <button class="tab is-active" data-tab="latest">최신</button>
          <button class="tab" data-tab="popular">인기</button>
          <button class="tab" data-tab="week">주간</button>
        </div>
        <ul class="mini-list is-active" data-panel="latest">
          $latestHtml
        </ul>
        <ul class="mini-list" data-panel="popular">
          $popularHtml
        </ul>
        <ul class="mini-list" data-panel="week">
          $weekHtml
        </ul>
      </div>

      <div class="col col-main">
        <div class="col-head">
          <h2 class="col-title">주요 뉴스</h2>
          <div class="col-nav">
            <button class="nav-btn" data-slide="prev" aria-label="이전 기사">&lsaquo;</button>
            <button class="nav-btn" data-slide="next" aria-label="다음 기사">&rsaquo;</button>
          </div>
        </div>
$(New-SlideHtml $slideList)
      </div>

      <div class="col col-right">
        <div class="col-head">
          <h2 class="col-title">트렌딩 나우</h2>
          <div class="col-nav">
            <button class="nav-btn" data-rank="prev" aria-label="위로">&#9650;</button>
            <button class="nav-btn" data-rank="next" aria-label="아래로">&#9660;</button>
          </div>
        </div>
        <div class="rank-viewport" data-rank-list>
          <ul class="mini-list rank-list">
          $trendHtml
          </ul>
        </div>
      </div>

    </section>
"@
}

# ---------------------------------------------------------
#  구조화 데이터(JSON-LD)
#
#  "이 페이지는 뉴스 기사이고, 쓴 곳은 블록미디어고, 발행일은 언제다" 를
#  검색엔진이 기계적으로 읽을 수 있게 적어두는 부분입니다. 화면에는 안 보입니다.
#
#  ★ 정직하게 적는 것이 중요합니다.
#    기사 본문을 쓴 것은 언론사이므로 author 는 언론사로 적고,
#    우리는 publisher(이 페이지를 낸 곳)로만 적습니다.
#    isBasedOn 에 원문 주소를 넣어 "이 글은 저것을 근거로 한다"를 명시합니다.
#    우리가 직접 쓴 주간 정리·가이드만 author 를 비트뉴스로 적습니다.
# ---------------------------------------------------------
function ConvertTo-JsonLdText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    # JSON 문자열 안에서 깨지지 않게, 그리고 </script> 로 태그가 닫히지 않게 처리합니다
    $t = $Text -replace '\\', '\\' -replace '"', '\"'
    $t = $t -replace "`r", '' -replace "`n", ' '
    $t = $t -replace '</', '<\/'
    return $t
}

function New-JsonLd {
    param(
        [string]$Kind,          # website | list | news | weekly | guide | guideIndex
        [string]$Url,           # 이 페이지의 전체 주소 (baseUrl 없으면 빈 값)
        [string]$Headline = '',
        [string]$Description = '',
        [string]$Image = '',
        [string]$DatePublished = '',
        [string]$AuthorName = '',
        [string]$BasedOn = '',
        $Crumbs = @()           # @( @{name=''; url=''} , ... )
    )

    # 주소가 없으면 구조화 데이터를 넣지 않습니다. 반쪽짜리보다 없는 게 낫습니다.
    if (-not $baseUrl) { return '' }

    $pub = '"publisher":{"@type":"Organization","name":"' + (ConvertTo-JsonLdText $siteName) + '","url":"' + $baseUrl + '/","logo":{"@type":"ImageObject","url":"' + $baseUrl + '/assets/img/og-image.png"}}'

    $blocks = New-Object System.Collections.ArrayList

    switch ($Kind) {
        'website' {
            [void]$blocks.Add('{"@context":"https://schema.org","@type":"WebSite","name":"' + (ConvertTo-JsonLdText $siteName) + '","url":"' + $baseUrl + '/","description":"' + (ConvertTo-JsonLdText $Description) + '","inLanguage":"ko-KR"}')
            [void]$blocks.Add('{"@context":"https://schema.org","@type":"Organization","name":"' + (ConvertTo-JsonLdText $siteName) + '","url":"' + $baseUrl + '/","logo":"' + $baseUrl + '/assets/img/og-image.png"}')
        }
        'list' {
            [void]$blocks.Add('{"@context":"https://schema.org","@type":"CollectionPage","name":"' + (ConvertTo-JsonLdText $Headline) + '","url":"' + $Url + '","description":"' + (ConvertTo-JsonLdText $Description) + '","inLanguage":"ko-KR",' + $pub + '}')
        }
        'news' {
            # 본문을 쓴 곳은 언론사다 — author 에 언론사를 적고 원문을 isBasedOn 으로 밝힌다
            $s = '{"@context":"https://schema.org","@type":"NewsArticle","headline":"' + (ConvertTo-JsonLdText $Headline) + '"'
            $s += ',"description":"' + (ConvertTo-JsonLdText $Description) + '"'
            $s += ',"url":"' + $Url + '","mainEntityOfPage":"' + $Url + '"'
            if ($DatePublished) { $s += ',"datePublished":"' + $DatePublished + '"' }
            if ($Image)         { $s += ',"image":["' + (ConvertTo-JsonLdText $Image) + '"]' }
            if ($AuthorName)    { $s += ',"author":{"@type":"Organization","name":"' + (ConvertTo-JsonLdText $AuthorName) + '"}' }
            if ($BasedOn)       { $s += ',"isBasedOn":"' + (ConvertTo-JsonLdText $BasedOn) + '"' }
            $s += ',"inLanguage":"ko-KR",' + $pub + '}'
            [void]$blocks.Add($s)
        }
        'weekly' {
            # 우리가 직접 쓴 글이다
            $s = '{"@context":"https://schema.org","@type":"NewsArticle","headline":"' + (ConvertTo-JsonLdText $Headline) + '"'
            $s += ',"description":"' + (ConvertTo-JsonLdText $Description) + '"'
            $s += ',"url":"' + $Url + '","mainEntityOfPage":"' + $Url + '"'
            if ($DatePublished) { $s += ',"datePublished":"' + $DatePublished + '"' }
            $s += ',"image":["' + $baseUrl + '/assets/img/og-image.png"]'
            $s += ',"author":{"@type":"Organization","name":"' + (ConvertTo-JsonLdText $siteName) + '"}'
            $s += ',"inLanguage":"ko-KR",' + $pub + '}'
            [void]$blocks.Add($s)
        }
        { $_ -in 'guide', 'guideIndex' } {
            $t = if ($Kind -eq 'guideIndex') { 'CollectionPage' } else { 'Article' }
            $s = '{"@context":"https://schema.org","@type":"' + $t + '","headline":"' + (ConvertTo-JsonLdText $Headline) + '"'
            $s += ',"description":"' + (ConvertTo-JsonLdText $Description) + '"'
            $s += ',"url":"' + $Url + '","mainEntityOfPage":"' + $Url + '"'
            $s += ',"image":["' + $baseUrl + '/assets/img/og-image.png"]'
            $s += ',"author":{"@type":"Organization","name":"' + (ConvertTo-JsonLdText $siteName) + '"}'
            $s += ',"inLanguage":"ko-KR",' + $pub + '}'
            [void]$blocks.Add($s)
        }
    }

    # 검색 결과에 "비트뉴스 › 가이드 › 바이낸스 가입 방법" 처럼 경로를 보여줍니다
    if (@($Crumbs).Count -gt 0) {
        $items = @()
        $pos = 1
        foreach ($c in @($Crumbs)) {
            $items += '{"@type":"ListItem","position":' + $pos + ',"name":"' + (ConvertTo-JsonLdText $c.name) + '","item":"' + $c.url + '"}'
            $pos++
        }
        [void]$blocks.Add('{"@context":"https://schema.org","@type":"BreadcrumbList","itemListElement":[' + ($items -join ',') + ']}')
    }

    if ($blocks.Count -eq 0) { return '' }
    return (($blocks | ForEach-Object { '  <script type="application/ld+json">' + $_ + '</script>' }) -join "`n")
}

# ---------------------------------------------------------
#  페이지 하나를 만들어 파일로 씁니다
# ---------------------------------------------------------
function Write-Page {
    param(
        [string]$RelPath,      # dist 안에서의 위치 (예: 'index.html', 'news/abc.html')
        [string]$Title,
        [string]$Description,
        [string]$Content,
        [string]$OgType = 'website',
        [string]$OgImage = '',
        [string]$BasePrefix = '',  # 하위 폴더면 '../'
        [string]$Ticker = '',
        [string]$JsonLd = ''
    )

    # canonical 은 sitemap 에 적은 주소와 글자까지 똑같아야 합니다.
    # 메인은 sitemap 에 "https://주소/" 로 넣으므로 index.html 을 떼어냅니다.
    # (안 맞추면 검색엔진이 같은 페이지를 두 개로 보고 점수를 나눠 갖습니다)
    $canonical = ''
    if ($baseUrl) {
        if ($RelPath -eq 'index.html') {
            $canonical = '<link rel="canonical" href="{0}/" />' -f $baseUrl
        } else {
            $canonical = '<link rel="canonical" href="{0}/{1}" />' -f $baseUrl, $RelPath
        }
    }
    # 공유 카드 이미지: 기사 사진이 있으면 그걸, 없으면 사이트 대표 이미지를 씁니다.
    # 대표 이미지는 주소가 완전해야 카카오톡·페이스북이 읽어갑니다(상대경로는 안 됨).
    $ogImageTag = ''
    if ($OgImage) {
        $ogImageTag = '<meta property="og:image" content="{0}" />' -f (Protect-Html $OgImage)
    } elseif ($baseUrl) {
        $ogImageTag = @'
<meta property="og:image" content="{0}/assets/img/og-image.png" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta name="twitter:card" content="summary_large_image" />
'@ -f $baseUrl
    }

    # 화면에 보이는 상호(로고·푸터)와 사업자 정보 줄.
    # 첫 화면에만 임시 상호를 쓰고, 나머지 페이지는 전부 원래 사이트 이름입니다.
    $brand   = $siteName
    $bizInfo = ''
    if ($RelPath -eq 'index.html' -and $tempHomeBrand) {
        $brand = $tempHomeBrand
        if ($tempHomeBizInfo) {
            $bizInfo = '      <p class="footer-meta">' + (Protect-Html $tempHomeBizInfo) + '</p>'
        }
    }

    $html = $template
    $html = $html.Replace('{{BRAND}}',       (Protect-Html $brand))
    $html = $html.Replace('{{BIZINFO}}',     $bizInfo)
    $html = $html.Replace('{{TITLE}}',       (Protect-Html $Title))
    $html = $html.Replace('{{DESCRIPTION}}', (Protect-Html $Description))
    $html = $html.Replace('{{CANONICAL}}',   $canonical)
    $html = $html.Replace('{{OG_TYPE}}',     $OgType)
    $html = $html.Replace('{{OG_IMAGE}}',    $ogImageTag)
    $html = $html.Replace('{{SITE_NAME}}',   (Protect-Html $siteName))
    $html = $html.Replace('{{TAGLINE}}',     (Protect-Html $cfg.site.tagline))
    $html = $html.Replace('{{BASE}}',        $BasePrefix)
    $html = $html.Replace('{{TICKER}}',      $Ticker)
    $html = $html.Replace('{{JSONLD}}',      $JsonLd)
    $html = $html.Replace('{{CONTENT}}',     $Content)
    $html = $html.Replace('{{UPDATED}}',     $updatedLabel)
    $html = $html.Replace('{{YEAR}}',        $nowUtc.AddHours(9).Year.ToString())

    $full = Join-Path $outPath ($RelPath -replace '/', [string][System.IO.Path]::DirectorySeparatorChar)
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $html, (New-Object System.Text.UTF8Encoding($false)))
}

# 기사 하나를 카드 모양 HTML 로 만듭니다
function New-Card {
    param($A, [string]$BasePrefix = '')

    $href = '{0}news/{1}.html' -f $BasePrefix, $A.id
    $pub = ConvertTo-Utc $A.published

    # alt 는 이미지 검색 유입과 이미지가 안 뜰 때를 위해 기사 제목을 넣습니다.
    # (속보 띠·작은 목록의 썸네일은 바로 옆에 제목이 있어 장식이므로 비워둡니다)
    if ($A.image) {
        $thumb = '<img class="card-thumb" src="{0}" alt="{1}" loading="lazy" />' -f `
                    (Protect-Html $A.image), (Protect-Html (Limit-Text $A.title 100))
    } else {
        $thumb = '<div class="card-thumb-empty">₿</div>'
    }

    return @"
      <article class="card">
        <a href="$href">
          $thumb
          <div class="card-body">
            <h3 class="card-title">$(Protect-Html $A.title)</h3>
            <p class="card-summary">$(Protect-Html (Limit-Text $A.summary 90))</p>
            <p class="card-meta">
              <span class="source-badge">$(Protect-Html $A.source)</span>
              <span>$(Format-Ago $pub)</span>
            </p>
          </div>
        </a>
      </article>
"@
}

# =========================================================
#  7. 목록 페이지 (1페이지, 2페이지 …)
# =========================================================
$tickerList = @($articles | Select-Object -First 10)
$tickerRoot = New-TickerHtml $tickerList ''
$tickerSub  = New-TickerHtml $tickerList '../'

$totalPages = [math]::Max(1, [math]::Ceiling($articles.Count / $PerPage))

for ($p = 1; $p -le $totalPages; $p++) {
    $slice = $articles | Select-Object -Skip (($p - 1) * $PerPage) -First $PerPage

    $cards = ($slice | ForEach-Object { New-Card $_ '' }) -join "`n"

    # 첫 페이지에만 특집 구역을 붙입니다
    $featured = ''
    if ($p -eq 1) { $featured = (New-FeaturedHtml) + "`n" }

    # 쪽 번호 만들기
    $pager = ''
    if ($totalPages -gt 1) {
        $links = @()
        if ($p -gt 1) {
            if ($p -eq 2) { $prev = 'index.html' } else { $prev = "page-$($p-1).html" }
            $links += '<a href="{0}">이전</a>' -f $prev
        }
        for ($i = 1; $i -le $totalPages; $i++) {
            # 페이지가 많으면 현재 위치 주변만 보여줍니다
            if ($totalPages -gt 9 -and $i -ne 1 -and $i -ne $totalPages -and [math]::Abs($i - $p) -gt 2) {
                if ([math]::Abs($i - $p) -eq 3) { $links += '<span>…</span>' }
                continue
            }
            if ($i -eq $p) {
                $links += '<span class="current">{0}</span>' -f $i
            } else {
                if ($i -eq 1) { $href = 'index.html' } else { $href = "page-$i.html" }
                $links += '<a href="{0}">{1}</a>' -f $href, $i
            }
        }
        if ($p -lt $totalPages) {
            $links += '<a href="page-{0}.html">다음</a>' -f ($p + 1)
        }
        $pager = "`n      <nav class=`"pagination`">`n        " + ($links -join "`n        ") + "`n      </nav>"
    }

    # 목록 페이지에도 h1 이 하나 있어야 합니다. 검색엔진이 "이 페이지가 무엇에 관한
    # 것인가"를 읽는 자리입니다. 보이는 모양은 그대로 두고 태그만 h1 으로 씁니다.
    if ($p -eq 1) { $heading = '비트코인 최신 뉴스' } else { $heading = "비트코인 최신 뉴스 — {0}페이지" -f $p }

    $content = @"
$featured    <h1 class="section-title">$heading</h1>
    <div class="card-grid">
$cards
    </div>$pager
"@

    if ($p -eq 1) {
        $relPath = 'index.html'
        # 첫 화면 제목(브라우저 탭 = 검색 결과의 파란 제목).
        # 상호만 임시값으로 바꾸고 "비트코인 뉴스 한눈에" 는 그대로 둡니다 —
        # 이 뒷부분이 첫 화면이 검색에 잡히는 핵심 낱말입니다.
        $homeBrand = if ($tempHomeBrand) { $tempHomeBrand } else { $siteName }
        $pageTitle = "$homeBrand — $($cfg.site.tagline)"
    } else {
        $relPath = "page-$p.html"
        $pageTitle = "$siteName — 최신 뉴스 ${p}페이지"
    }

    # 첫 페이지는 사이트 전체 정보를, 나머지 쪽은 목록 정보를 알려줍니다
    $listUrl = ''
    if ($baseUrl) { $listUrl = if ($p -eq 1) { "$baseUrl/" } else { "$baseUrl/$relPath" } }
    $listKind = if ($p -eq 1) { 'website' } else { 'list' }
    $listLd = New-JsonLd -Kind $listKind -Url $listUrl -Headline $heading -Description $cfg.site.description

    Write-Page -RelPath $relPath -Title $pageTitle -Description $cfg.site.description `
               -Content $content -OgType 'website' -Ticker $tickerRoot -JsonLd $listLd
}

Write-Host ("  목록 페이지 {0}쪽 생성" -f $totalPages)

# =========================================================
#  8. 기사별 페이지
# =========================================================
foreach ($a in $articles) {
    $pub = ConvertTo-Utc $a.published

    $thumb = ''
    if ($a.image) {
        $thumb = '<img class="article-thumb" src="{0}" alt="{1}" />' -f `
                    (Protect-Html $a.image), (Protect-Html (Limit-Text $a.title 100))
    }

    $authorPart = ''
    if ($a.author) { $authorPart = '<span>{0}</span>' -f (Protect-Html $a.author) }

    $tags = ''
    if ($a.categories -and @($a.categories).Count -gt 0) {
        $tagHtml = (@($a.categories) | ForEach-Object { '<span class="tag">#{0}</span>' -f (Protect-Html $_) }) -join "`n        "
        $tags = "`n      <div class=`"tag-list`">`n        $tagHtml`n      </div>"
    }

    # 지금 뜨는 기사 5건을 아래에 붙입니다
    $rel = @($byHot | Where-Object { $_.id -ne $a.id } | Select-Object -First 5)
    $relHtml = ''
    if ($rel.Count -gt 0) {
        $items = ($rel | ForEach-Object {
            '<li><a href="{0}.html">{1}<span class="related-meta">{2} · {3}</span></a></li>' -f `
                $_.id, (Protect-Html $_.title), (Protect-Html $_.source), (Format-Ago (ConvertTo-Utc $_.published))
        }) -join "`n          "
        $relHtml = @"

    <section class="related">
      <h2>지금 뜨는 뉴스</h2>
      <ul>
          $items
      </ul>
    </section>
"@
    }

    $content = @"
    <article class="article">
      <p class="breadcrumb"><a href="../index.html">$(Protect-Html $siteName)</a> › 기사</p>

      <h1 class="article-title">$(Protect-Html $a.title)</h1>

      <div class="article-meta">
        <span class="source-badge">$(Protect-Html $a.source)</span>
        $authorPart
        <span>$(Format-Kst $pub)</span>
      </div>

      $thumb

      <p class="article-summary">$(Protect-Html $a.summary)</p>

      <div class="source-box">
        <p>
          이 글은 <strong>$(Protect-Html $a.source)</strong>가 공개한 요약이며, 기사 전문과 저작권은
          해당 언론사에 있습니다. 전체 내용은 아래에서 확인하세요.
        </p>
        <a class="source-link" href="$(Protect-Html $a.link)" target="_blank" rel="noopener nofollow">
          원문 전체 보기 →
        </a>
      </div>$tags

      <a class="back-link" href="../index.html">← 최신 뉴스 목록으로</a>
    </article>$relHtml
"@

    # 이 기사 페이지의 구조화 데이터.
    # 본문을 쓴 곳은 언론사이므로 author 는 언론사로, 원문은 isBasedOn 으로 밝힙니다.
    $newsLd = ''
    if ($baseUrl) {
        $newsUrl = "$baseUrl/news/$($a.id).html"
        $newsLd = New-JsonLd -Kind 'news' -Url $newsUrl `
                    -Headline $a.title -Description (Limit-Text $a.summary 155) `
                    -Image $a.image -DatePublished $pub.ToString('o') `
                    -AuthorName $a.source -BasedOn $a.link `
                    -Crumbs @(
                        @{ name = $siteName; url = "$baseUrl/" },
                        @{ name = '뉴스';    url = $newsUrl }
                    )
    }

    Write-Page -RelPath ('news/{0}.html' -f $a.id) `
               -Title ('{0} | {1}' -f $a.title, $siteName) `
               -Description (Limit-Text $a.summary 155) `
               -Content $content -OgType 'article' -OgImage $a.image `
               -BasePrefix '../' -Ticker $tickerSub -JsonLd $newsLd
}

Write-Host ("  기사 페이지 {0}개 생성" -f $articles.Count)

# =========================================================
#  9. 404 페이지
# =========================================================
Write-Page -RelPath '404.html' -Title "페이지를 찾을 수 없습니다 | $siteName" `
           -Description '요청하신 페이지가 없습니다.' -Ticker $tickerRoot -Content @"
    <div class="empty">
      <h1 class="article-title">404</h1>
      <p>찾으시는 페이지가 없거나 주소가 바뀌었습니다.</p>
      <p><a class="source-link" href="index.html" style="margin-top:1.5rem">최신 뉴스 보기</a></p>
    </div>
"@

# =========================================================
#  9-1. 주간 정리 섹션 (/weekly/)
#
#  weekly\posts\*.html 이 사람이 쓴 본문이고, 목차는 weekly\weekly.json 에 있습니다.
#  글 아래에 붙는 "그 주 주요 기사" 목록은 from~to 날짜를 보고 자동으로 만듭니다.
#  뉴스 쪽 껍데기(templates\base.html)를 그대로 씁니다 — 같은 사이트로 보여야 하니까요.
# =========================================================
$weeklyDir = Join-Path $root 'weekly'
$weeklyUrls = @()

if (Test-Path $weeklyDir) {
    $wCfg = (Get-Content (Join-Path $weeklyDir 'weekly.json') -Raw -Encoding UTF8) | ConvertFrom-Json
    $wOut = Join-Path $outPath $wCfg.section.dir
    New-Item -ItemType Directory -Path $wOut -Force | Out-Null

    $wPosts = @($wCfg.posts)

    foreach ($post in $wPosts) {
        $fragPath = Join-Path (Join-Path $weeklyDir 'posts') ($post.slug + '.html')
        if (-not (Test-Path $fragPath)) {
            Write-Host ("  주간 정리 본문 없음: {0}" -f $post.slug) -ForegroundColor DarkYellow
            continue
        }
        $frag = Get-Content $fragPath -Raw -Encoding UTF8

        # 이 글이 다루는 기간의 기사를 인기순으로 뽑아 아래에 붙입니다
        $fromD = ConvertTo-Utc ($post.from + 'T00:00:00Z')
        $toD   = (ConvertTo-Utc ($post.to + 'T00:00:00Z')).AddDays(1)
        $inRange = @($byHot | Where-Object {
            $d = ConvertTo-Utc $_.published
            $d -ge $fromD -and $d -lt $toD
        } | Select-Object -First 12)

        $linkHtml = ''
        if ($inRange.Count -gt 0) {
            $rows = ($inRange | ForEach-Object {
                '<li><a href="../news/{0}.html">{1}<span class="related-meta">{2} · {3}</span></a></li>' -f `
                    $_.id, (Protect-Html $_.title), (Protect-Html $_.source), (Format-Kst (ConvertTo-Utc $_.published))
            }) -join "`n          "
            $linkHtml = @"

    <section class="related">
      <h2>이 기간의 주요 기사 $($inRange.Count)건</h2>
      <ul>
          $rows
      </ul>
    </section>
"@
        }

        $content = @"
    <article class="article wk-article">
      <p class="breadcrumb"><a href="../index.html">$(Protect-Html $siteName)</a> › <a href="index.html">주간 정리</a></p>

      <h1 class="article-title">$(Protect-Html $post.title)</h1>
      <p class="wk-subtitle">$(Protect-Html $post.subtitle)</p>

$frag

      <a class="back-link" href="index.html">← 주간 정리 목록으로</a>
    </article>$linkHtml
"@

        # 주간 정리 제목은 이미 그 자체로 길고 구체적입니다.
        # 여기에 "| 비트뉴스"까지 붙이면 30자를 넘겨 검색 결과에서 뒤가 잘립니다.
        $wTitle = $post.title
        if ($wTitle.Length -gt 30) {
            Write-Host ("  주의: 주간 정리 제목이 {0}자입니다({1}). 검색 결과에서 잘릴 수 있습니다." -f `
                        $wTitle.Length, $post.slug) -ForegroundColor DarkYellow
        }

        $weeklyLd = ''
        if ($baseUrl) {
            $wUrl = "$baseUrl/$($wCfg.section.dir)/$($post.slug).html"
            $weeklyLd = New-JsonLd -Kind 'weekly' -Url $wUrl `
                          -Headline $post.title -Description $post.desc `
                          -DatePublished ((ConvertTo-Utc ($post.published + 'T00:00:00Z')).ToString('o')) `
                          -Crumbs @(
                              @{ name = $siteName; url = "$baseUrl/" },
                              @{ name = '주간 정리'; url = "$baseUrl/$($wCfg.section.dir)/index.html" },
                              @{ name = $post.title; url = $wUrl }
                          )
        }

        Write-Page -RelPath ('{0}/{1}.html' -f $wCfg.section.dir, $post.slug) `
                   -Title $wTitle `
                   -Description $post.desc -Content $content -OgType 'article' `
                   -BasePrefix '../' -Ticker $tickerSub -JsonLd $weeklyLd
        $weeklyUrls += $post.slug
    }

    # 주간 정리 목록 페이지
    $cards = ($wPosts | ForEach-Object {
        @"
      <article class="card wk-card">
        <a href="$($_.slug).html">
          <div class="card-body">
            <p class="wk-card-date">$(Protect-Html $_.subtitle)</p>
            <h3 class="card-title">$(Protect-Html $_.title)</h3>
            <p class="card-summary">$(Protect-Html (Limit-Text $_.desc 110))</p>
          </div>
        </a>
      </article>
"@
    }) -join "`n"

    $wIndex = @"
    <h1 class="section-title">주간 정리</h1>
    <p class="wk-intro">$(Protect-Html $wCfg.section.description)</p>
    <div class="card-grid">
$cards
    </div>
"@

    Write-Page -RelPath ('{0}/index.html' -f $wCfg.section.dir) `
               -Title ('주간 정리 | {0}' -f $siteName) `
               -Description $wCfg.section.description -Content $wIndex `
               -BasePrefix '../' -Ticker $tickerSub
    $weeklyUrls += 'index'

    Write-Host ("  주간 정리 {0}개 생성 (/{1}/)" -f $weeklyUrls.Count, $wCfg.section.dir)
}

# =========================================================
#  9-2. 코인 거래소 섹션 (/exchange/ + 거래소별 가이드)
#
#  guide\ 폴더의 내용을 dist\ 아래로 만들어 냅니다.
#    dist\exchange\index.html   ← guide\hub.html        (거래소 순위 허브)
#    dist\<거래소 dir>\*.html   ← guide\<거래소 id>\*.html (거래소별 7장)
#
#  순위·목차·추천코드는 전부 guide\guide.json 에 있습니다.
#  거래소를 추가하려면 guide\<새 id>\ 폴더에 본문 조각 7개를 넣고
#  guide.json 의 exchanges 에 한 칸 추가하면 됩니다. 이 파일은 고치지 않아도 됩니다.
#  exchanges 에 적힌 순서가 그대로 1위·2위·3위가 됩니다.
# =========================================================
$guideDir = Join-Path $root 'guide'
$guideUrls = @()   # sitemap 용. @{ dir = ''; file = '' } 꼴로 모읍니다

if (Test-Path $guideDir) {
    $gCfg = (Get-Content (Join-Path $guideDir 'guide.json') -Raw -Encoding UTF8) | ConvertFrom-Json
    $gTpl = Get-Content (Join-Path $guideDir 'template.html') -Raw -Encoding UTF8

    $gHub = $gCfg.hub
    $gExs = @($gCfg.exchanges)

    $gCssSrc = Join-Path $guideDir 'guide.css'
    $gJsSrc  = Join-Path $guideDir 'guide.js'

    $gSideNote = '순서대로 읽으면 가입 → 입금 → 거래 흐름이 이어집니다.'

    # ---------------------------------------------------------
    #  거래소 한 곳의 가입 유도 카드
    # ---------------------------------------------------------
    function New-CtaCard {
        param($Ex)
        $chips = @()
        foreach ($c in @($Ex.referral.chips)) {
            $chips += ('          <span class="g-chip">{0}</span>' -f (Protect-Html $c))
        }
        $chipHtml = ($chips -join "`n")
        # 바이비트는 "가입코드" 라고 부릅니다. guide.json 에 codeLabel 이 있으면 그걸 씁니다.
        $codeLabel = $Ex.referral.codeLabel
        if ([string]::IsNullOrWhiteSpace($codeLabel)) { $codeLabel = '추천코드' }
        return @"
      <div class="g-cta-card">
        <span class="g-cta-tag">초보자용 시작 가이드</span>
        <h2>$(Protect-Html $codeLabel)를 적용해서<br />$(Protect-Html $Ex.name) 가입하기</h2>
        <p>$(Protect-Html $Ex.referral.pitch)</p>
        <div class="g-chips">
$chipHtml
        </div>
        <div class="g-code-row">
          <span>$(Protect-Html $codeLabel)</span>
          <span class="g-code">$(Protect-Html $Ex.referral.code)</span>
          <button class="g-copy" data-copy="$(Protect-Html $Ex.referral.code)">복사</button>
        </div>
        <a class="g-cta-btn" href="$(Protect-Html $Ex.referral.link)" target="_blank" rel="noopener nofollow sponsored">$(Protect-Html $Ex.referral.ctaLabel) →</a>
        <p style="margin-top:0.8rem;font-size:0.8rem">
          할인율은 계정·지역·거래 상품에 따라 다릅니다. 가입 화면에서 실제 적용 내용을 확인하세요.
          본 페이지는 투자 권유가 아닌 정보 제공용 안내입니다.
        </p>
      </div>
"@
    }

    # 거래소 한 곳의 사이드바 목차
    function New-GuideToc {
        param($Ex, [string]$Current)
        $rows = @()
        foreach ($pg in @($Ex.pages)) {
            $cls = ''
            if ($pg.file -eq $Current) { $cls = ' class="is-current"' }
            $rows += ('          <li><a href="{0}.html"{1}><span class="g-toc-num">{2}</span>{3}</a></li>' -f `
                        $pg.file, $cls, $pg.num, (Protect-Html $pg.title))
        }
        return ($rows -join "`n")
    }

    # 거래소 가이드 홈에 들어갈 카드 목록
    function New-GuideCards {
        param($Ex)
        $rows = @()
        foreach ($pg in @($Ex.pages)) {
            $rows += @"
          <a class="g-card" href="$($pg.file).html">
            <span class="g-card-num">$($pg.num)</span>
            <h3>$(Protect-Html $pg.title)</h3>
            <p>$(Protect-Html $pg.subtitle)</p>
          </a>
"@
        }
        return "        <div class=`"g-cards`">`n" + ($rows -join "`n") + "`n        </div>"
    }

    # 가이드 홈 맨 아래 "다른 거래소도 보기"
    function New-OtherExchanges {
        param([string]$CurrentId)
        $rows = @()
        foreach ($ex in $gExs) {
            if ($ex.id -eq $CurrentId) { continue }
            $rows += @"
          <a href="../$($ex.dir)/index.html">
            <span class="g-other-rank">$($ex.rank)위</span>
            <span class="g-other-name">$(Protect-Html $ex.name) 가이드</span>
            <span class="g-other-desc">현물 $(Protect-Html $ex.specs.spot)</span>
          </a>
"@
        }
        $inner = ($rows -join "`n")
        return @"
      <section class="g-sec">
        <h2>다른 거래소도 보기</h2>
        <div class="g-other">
$inner
        </div>
        <p class="g-side-note" style="margin-top:0.9rem"><a href="../$($gHub.dir)/index.html">코인 거래소 순위 전체 보기 →</a></p>
      </section>
"@
    }

    # ---------------------------------------------------------
    #  허브에 들어갈 순위 카드와 비교표
    # ---------------------------------------------------------
    $gRankRows = @()
    foreach ($ex in $gExs) {
        $goods = @()
        foreach ($g in @($ex.card.good)) {
            $goods += ('                <li>{0}</li>' -f (Protect-Html $g))
        }
        $goodHtml = ($goods -join "`n")
        $gRankRows += @"
        <article class="g-rank g-rank--$($ex.rank)">
          <div class="g-rank-head">
            <span class="g-rank-medal">$($ex.rank)위</span>
            <span class="g-rank-name">$(Protect-Html $ex.name)</span>
            <span class="g-rank-en">$(Protect-Html $ex.nameEn)</span>
          </div>
          <p class="g-rank-summary">$(Protect-Html $ex.card.summary)</p>
          <div class="g-rank-cols">
            <div>
              <h4>이런 점이 좋습니다</h4>
              <ul class="g-rank-good">
$goodHtml
              </ul>
            </div>
            <div>
              <h4>알아둘 점</h4>
              <p class="g-rank-watch">$(Protect-Html $ex.card.watch)</p>
            </div>
          </div>
          <div class="g-rank-fees">
            <div class="g-rank-fee">
              <span class="g-rank-fee-label">현물</span>
              <span class="g-rank-fee-value">$(Protect-Html $ex.specs.spot)</span>
              <span class="g-rank-fee-note">$(Protect-Html $ex.specs.spotNote)</span>
            </div>
            <div class="g-rank-fee">
              <span class="g-rank-fee-label">선물</span>
              <span class="g-rank-fee-value">$(Protect-Html $ex.specs.futures)</span>
              <span class="g-rank-fee-note">$(Protect-Html $ex.specs.futuresNote)</span>
            </div>
          </div>
          <div class="g-rank-actions">
            <a class="g-rank-btn" href="$(Protect-Html $ex.referral.link)" target="_blank" rel="noopener nofollow sponsored">$(Protect-Html $ex.name) 가입하기 →</a>
            <a class="g-rank-btn g-rank-btn--ghost" href="../$($ex.dir)/index.html">가이드 6편 보기</a>
            <span class="g-rank-code">코드 <b>$(Protect-Html $ex.referral.code)</b></span>
          </div>
        </article>
"@
    }
    $gRankHtml = "        <div class=`"g-ranks`">`n" + ($gRankRows -join "`n") + "`n        </div>"
    $gRankNote = '      <p class="g-rank-note">' + (Protect-Html $gHub.rankNote) + '</p>'

    # 비교표 — 한 줄 만들기
    function New-CompareRow {
        param([string]$Label, [string]$Key, [string]$NoteKey = '')
        $tds = ''
        foreach ($ex in $gExs) {
            $cell = Protect-Html $ex.specs.$Key
            if ($NoteKey -and $ex.specs.$NoteKey) {
                $cell += '<small>' + (Protect-Html $ex.specs.$NoteKey) + '</small>'
            }
            $tds += ('<td>{0}</td>' -f $cell)
        }
        return ('              <tr><td>{0}</td>{1}</tr>' -f $Label, $tds)
    }

    $gCmpHead = ''
    $gCmpCode = ''
    foreach ($ex in $gExs) {
        $gCmpHead += ('<th>{0}위 {1}</th>' -f $ex.rank, (Protect-Html $ex.name))
        $gCmpCode += ('<td><b>{0}</b></td>' -f (Protect-Html $ex.referral.code))
    }

    $gCompare = @"
        <div class="g-table-wrap g-compare">
          <table class="g-table">
            <thead><tr><th>구분</th>$gCmpHead</tr></thead>
            <tbody>
$(New-CompareRow -Label '현물 수수료' -Key 'spot' -NoteKey 'spotNote')
$(New-CompareRow -Label '선물 수수료' -Key 'futures' -NoteKey 'futuresNote')
$(New-CompareRow -Label '코인 입금' -Key 'deposit')
$(New-CompareRow -Label '코인 출금' -Key 'withdraw')
              <tr><td>가입 코드</td>$gCmpCode</tr>
            </tbody>
          </table>
        </div>
"@

    # ---------------------------------------------------------
    #  페이지 한 장을 만들어 파일로 씁니다 (허브·가이드 공용)
    # ---------------------------------------------------------
    function Write-GuidePage {
        param(
            [string]$OutDir, [string]$Dir, [string]$File,
            [string]$Title, [string]$Desc, [string]$Fragment,
            [string]$Badge, [string]$TocLabel, [string]$SideNote,
            [string]$TocHtml, [string]$NavLinks, [string]$Crumb,
            [string]$RefLink, [string]$CtaLabel,
            [string]$Accent, [string]$AccentSoft,
            [string]$Kind, $Crumbs = @(), [string]$NextHtml = ''
        )

        $html = $gTpl

        $canonical = ''
        if ($baseUrl) {
            $canonical = '<link rel="canonical" href="{0}/{1}/{2}.html" />' -f $baseUrl, $Dir, $File
        }

        $gOgImage = ''
        if ($baseUrl) {
            $gOgImage = @'
<meta property="og:image" content="{0}/assets/img/og-image.png" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta name="twitter:card" content="summary_large_image" />
'@ -f $baseUrl
        }

        # 구조화 데이터 — 가이드는 우리가 직접 쓴 글입니다
        $gLd = ''
        if ($baseUrl) {
            $gUrl = '{0}/{1}/{2}.html' -f $baseUrl, $Dir, $File
            $gLd = New-JsonLd -Kind $Kind -Url $gUrl -Headline $Title -Description $Desc -Crumbs $Crumbs
        }

        # 거래소마다 강조색이 다릅니다 (guide.css 의 --g-gold 를 덮어씁니다)
        $accentStyle = ''
        if ($Accent) { $accentStyle = ' style="--g-gold:{0};--g-gold-soft:{1}"' -f $Accent, $AccentSoft }

        $html = $html.Replace('{{TITLE}}',        (Protect-Html $Title))
        $html = $html.Replace('{{DESCRIPTION}}',  (Protect-Html $Desc))
        $html = $html.Replace('{{CANONICAL}}',    $canonical)
        $html = $html.Replace('{{JSONLD}}',       $gLd)
        $html = $html.Replace('{{OG_IMAGE}}',     $gOgImage)
        $html = $html.Replace('{{ACCENT_STYLE}}', $accentStyle)
        $html = $html.Replace('{{SITE_NAME}}',    (Protect-Html $siteName))
        $html = $html.Replace('{{HOME_HREF}}',    '../index.html')
        $html = $html.Replace('{{BADGE}}',        (Protect-Html $Badge))
        $html = $html.Replace('{{TOC_LABEL}}',    (Protect-Html $TocLabel))
        $html = $html.Replace('{{SIDE_NOTE}}',    $SideNote)
        $html = $html.Replace('{{NAV_LINKS}}',    $NavLinks)
        $html = $html.Replace('{{CRUMB}}',        $Crumb)
        $html = $html.Replace('{{REF_LINK}}',     (Protect-Html $RefLink))
        $html = $html.Replace('{{CTA_LABEL}}',    (Protect-Html $CtaLabel))
        $html = $html.Replace('{{NAV}}',          $TocHtml)
        $html = $html.Replace('{{CONTENT}}',      ($Fragment + $NextHtml))
        $html = $html.Replace('{{UPDATED}}',      $updatedLabel)
        $html = $html.Replace('{{YEAR}}',         $nowUtc.AddHours(9).Year.ToString())

        [System.IO.File]::WriteAllText((Join-Path $OutDir ($File + '.html')), $html, (New-Object System.Text.UTF8Encoding($false)))
    }

    # ---------------------------------------------------------
    #  허브 (/exchange/index.html)
    # ---------------------------------------------------------
    $gHubOut = Join-Path $outPath $gHub.dir
    New-Item -ItemType Directory -Path $gHubOut -Force | Out-Null
    Copy-Item $gCssSrc -Destination $gHubOut -Force
    Copy-Item $gJsSrc  -Destination $gHubOut -Force

    $hubFrag = Get-Content (Join-Path $guideDir 'hub.html') -Raw -Encoding UTF8
    $hubFrag = $hubFrag.Replace('{{RANK_NOTE}}', $gRankNote)
    $hubFrag = $hubFrag.Replace('{{RANK_CARDS}}', $gRankHtml)
    $hubFrag = $hubFrag.Replace('{{COMPARE_TABLE}}', $gCompare)

    $hubTocRows = @()
    $hubNavRows = @()
    foreach ($ex in $gExs) {
        $hubTocRows += ('          <li><a href="../{0}/index.html"><span class="g-toc-num">{1}위</span>{2}</a></li>' -f `
                         $ex.dir, $ex.rank, (Protect-Html $ex.name))
        $hubNavRows += ('        <a class="g-nav-link" href="../{0}/index.html">{1}</a>' -f `
                         $ex.dir, (Protect-Html $ex.name))
    }

    $gTop = $gExs[0]
    $hubTitle = $gHub.pageTitle
    if ([string]::IsNullOrWhiteSpace($hubTitle)) { $hubTitle = '{0} | {1}' -f $gHub.name, $siteName }

    $hubCrumbs = @(
        @{ name = $siteName;  url = "$baseUrl/" },
        @{ name = $gHub.name; url = ('{0}/{1}/index.html' -f $baseUrl, $gHub.dir) }
    )

    Write-GuidePage -OutDir $gHubOut -Dir $gHub.dir -File 'index' `
        -Title $hubTitle -Desc $gHub.description -Fragment $hubFrag `
        -Badge $gHub.name -TocLabel '거래소 목록' `
        -SideNote '순위는 이 사이트가 정한 소개 순서입니다. 거래소 이름을 누르면 가이드 6편으로 갑니다.' `
        -TocHtml ($hubTocRows -join "`n") -NavLinks ($hubNavRows -join "`n") `
        -Crumb ('<a href="../index.html">홈</a> / {0}' -f (Protect-Html $gHub.name)) `
        -RefLink $gTop.referral.link -CtaLabel ('{0}위 {1} 가입하기' -f $gTop.rank, $gTop.name) `
        -Accent $gTop.accent -AccentSoft $gTop.accentSoft `
        -Kind 'guideIndex' -Crumbs $hubCrumbs

    $guideUrls += @{ dir = $gHub.dir; file = 'index' }

    # ---------------------------------------------------------
    #  거래소별 가이드
    # ---------------------------------------------------------
    foreach ($ex in $gExs) {
        $exSrc = Join-Path $guideDir $ex.id
        if (-not (Test-Path $exSrc)) {
            Write-Host ("  거래소 폴더 없음: guide\{0}" -f $ex.id) -ForegroundColor DarkYellow
            continue
        }

        $exOut = Join-Path $outPath $ex.dir
        New-Item -ItemType Directory -Path $exOut -Force | Out-Null
        Copy-Item $gCssSrc -Destination $exOut -Force
        Copy-Item $gJsSrc  -Destination $exOut -Force

        $ctaCard   = New-CtaCard -Ex $ex
        $cardsHtml = New-GuideCards -Ex $ex
        $otherHtml = New-OtherExchanges -CurrentId $ex.id

        $exNavRows = @()
        $exNavRows += ('        <a class="g-nav-link" href="../{0}/index.html">{1}</a>' -f $gHub.dir, (Protect-Html $gHub.name))
        $exNavRows += ('        <a class="g-nav-link" href="index.html">{0} 홈</a>' -f (Protect-Html $ex.name))
        $exNavLinks = ($exNavRows -join "`n")

        $exCrumbHome = '<a href="../index.html">홈</a> / <a href="../{0}/index.html">{1}</a> / {2}' -f `
                        $gHub.dir, (Protect-Html $gHub.name), (Protect-Html $ex.name)
        $exCrumbPage = '<a href="../index.html">홈</a> / <a href="../{0}/index.html">{1}</a> / <a href="index.html">{2}</a>' -f `
                        $gHub.dir, (Protect-Html $gHub.name), (Protect-Html $ex.name)

        $exPages = @($ex.pages)

        # 거래소 가이드 홈
        $exIdxFrag = Get-Content (Join-Path $exSrc 'index.html') -Raw -Encoding UTF8
        $exIdxFrag = $exIdxFrag.Replace('{{CTA_CARD}}', $ctaCard)
        $exIdxFrag = $exIdxFrag.Replace('{{CARDS}}', $cardsHtml)
        $exIdxFrag = $exIdxFrag.Replace('{{OTHER_EXCHANGES}}', $otherHtml)

        $exTitle = $ex.pageTitle
        if ([string]::IsNullOrWhiteSpace($exTitle)) { $exTitle = '{0} 가이드 | {1}' -f $ex.name, $siteName }

        $exIdxCrumbs = @(
            @{ name = $siteName;  url = "$baseUrl/" },
            @{ name = $gHub.name; url = ('{0}/{1}/index.html' -f $baseUrl, $gHub.dir) },
            @{ name = ('{0} 가이드' -f $ex.name); url = ('{0}/{1}/index.html' -f $baseUrl, $ex.dir) }
        )

        Write-GuidePage -OutDir $exOut -Dir $ex.dir -File 'index' `
            -Title $exTitle -Desc $ex.description -Fragment $exIdxFrag `
            -Badge $ex.name -TocLabel '가이드 목차' -SideNote $gSideNote `
            -TocHtml (New-GuideToc -Ex $ex -Current '') -NavLinks $exNavLinks `
            -Crumb $exCrumbHome `
            -RefLink $ex.referral.link -CtaLabel $ex.referral.ctaLabel `
            -Accent $ex.accent -AccentSoft $ex.accentSoft `
            -Kind 'guideIndex' -Crumbs $exIdxCrumbs

        $guideUrls += @{ dir = $ex.dir; file = 'index' }

        # 각 가이드 6장
        for ($gi = 0; $gi -lt $exPages.Count; $gi++) {
            $pg = $exPages[$gi]
            $fragPath = Join-Path $exSrc ($pg.file + '.html')
            if (-not (Test-Path $fragPath)) {
                Write-Host ("  가이드 본문 없음: guide\{0}\{1}" -f $ex.id, $pg.file) -ForegroundColor DarkYellow
                continue
            }
            $frag = (Get-Content $fragPath -Raw -Encoding UTF8).Replace('{{CTA_CARD}}', $ctaCard)

            # 이전 / 다음 가이드 링크
            $stepLinks = @()
            if ($gi -gt 0) {
                $prevPg = $exPages[$gi - 1]
                $stepLinks += ('<a href="{0}.html"><span>← 이전</span>{1}</a>' -f $prevPg.file, (Protect-Html $prevPg.title))
            }
            if ($gi -lt $exPages.Count - 1) {
                $nextPg = $exPages[$gi + 1]
                $stepLinks += ('<a href="{0}.html" style="text-align:right"><span>다음 →</span>{1}</a>' -f $nextPg.file, (Protect-Html $nextPg.title))
            }
            $nextHtml = ''
            if ($stepLinks.Count -gt 0) {
                $nextHtml = "`n      <nav class=`"g-next`">`n        " + ($stepLinks -join "`n        ") + "`n      </nav>"
            }

            $pgCrumbs = @(
                @{ name = $siteName;  url = "$baseUrl/" },
                @{ name = $gHub.name; url = ('{0}/{1}/index.html' -f $baseUrl, $gHub.dir) },
                @{ name = ('{0} 가이드' -f $ex.name); url = ('{0}/{1}/index.html' -f $baseUrl, $ex.dir) },
                @{ name = $pg.title;  url = ('{0}/{1}/{2}.html' -f $baseUrl, $ex.dir, $pg.file) }
            )

            Write-GuidePage -OutDir $exOut -Dir $ex.dir -File $pg.file `
                -Title ('{0} | {1}' -f $pg.title, $siteName) -Desc $pg.desc -Fragment $frag `
                -Badge $ex.name -TocLabel '가이드 목차' -SideNote $gSideNote `
                -TocHtml (New-GuideToc -Ex $ex -Current $pg.file) -NavLinks $exNavLinks `
                -Crumb $exCrumbPage `
                -RefLink $ex.referral.link -CtaLabel $ex.referral.ctaLabel `
                -Accent $ex.accent -AccentSoft $ex.accentSoft `
                -Kind 'guide' -Crumbs $pgCrumbs -NextHtml $nextHtml

            $guideUrls += @{ dir = $ex.dir; file = $pg.file }
        }
    }

    Write-Host ("  코인 거래소 페이지 {0}개 생성 (거래소 {1}곳 + 순위 허브 /{2}/)" -f `
                 $guideUrls.Count, $gExs.Count, $gHub.dir)
}

# =========================================================
#  10. 검색엔진용 파일 (robots.txt / sitemap.xml / feed.xml)
# =========================================================
function Save-Text {
    param([string]$RelPath, [string]$Text)
    $full = Join-Path $outPath $RelPath
    [System.IO.File]::WriteAllText($full, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$sitemapLine = ''
if ($baseUrl) { $sitemapLine = "Sitemap: $baseUrl/sitemap.xml" }
Save-Text 'robots.txt' @"
User-agent: *
Allow: /

$sitemapLine
"@

# 주소가 정해져야 sitemap 과 RSS 가 의미가 있습니다
if ($baseUrl) {
    $urls = New-Object System.Text.StringBuilder
    [void]$urls.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$urls.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
    [void]$urls.AppendLine("  <url><loc>$baseUrl/</loc><changefreq>hourly</changefreq><priority>1.0</priority></url>")
    for ($p = 2; $p -le $totalPages; $p++) {
        [void]$urls.AppendLine("  <url><loc>$baseUrl/page-$p.html</loc><changefreq>daily</changefreq></url>")
    }
    foreach ($a in $articles) {
        $lm = (ConvertTo-Utc $a.published).ToString('yyyy-MM-dd')
        [void]$urls.AppendLine("  <url><loc>$baseUrl/news/$($a.id).html</loc><lastmod>$lm</lastmod></url>")
    }
    # 거래소 허브와 가이드 페이지도 검색엔진에 알립니다 (뉴스와 달리 잘 바뀌지 않으므로 monthly)
    # $guideUrls 는 @{ dir = 'binance-guide'; file = '01-signup' } 꼴입니다
    foreach ($gu in $guideUrls) {
        [void]$urls.AppendLine("  <url><loc>$baseUrl/$($gu.dir)/$($gu.file).html</loc><changefreq>monthly</changefreq><priority>0.8</priority></url>")
    }
    # 주간 정리는 우리가 직접 쓴 글이라 우선순위를 높게 둡니다
    foreach ($wu in $weeklyUrls) {
        [void]$urls.AppendLine("  <url><loc>$baseUrl/weekly/$wu.html</loc><changefreq>weekly</changefreq><priority>0.9</priority></url>")
    }
    [void]$urls.AppendLine('</urlset>')
    Save-Text 'sitemap.xml' $urls.ToString()

    $rss = New-Object System.Text.StringBuilder
    [void]$rss.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$rss.AppendLine('<rss version="2.0"><channel>')
    [void]$rss.AppendLine("  <title>$(Protect-Html $siteName)</title>")
    [void]$rss.AppendLine("  <link>$baseUrl/</link>")
    [void]$rss.AppendLine("  <description>$(Protect-Html $cfg.site.description)</description>")
    [void]$rss.AppendLine('  <language>ko</language>')
    foreach ($a in ($articles | Select-Object -First 30)) {
        [void]$rss.AppendLine('  <item>')
        [void]$rss.AppendLine("    <title>$(Protect-Html $a.title)</title>")
        [void]$rss.AppendLine("    <link>$baseUrl/news/$($a.id).html</link>")
        [void]$rss.AppendLine("    <guid>$baseUrl/news/$($a.id).html</guid>")
        [void]$rss.AppendLine("    <pubDate>$((ConvertTo-Utc $a.published).ToString('r'))</pubDate>")
        [void]$rss.AppendLine("    <description>$(Protect-Html $a.summary)</description>")
        [void]$rss.AppendLine('  </item>')
    }
    [void]$rss.AppendLine('</channel></rss>')
    Save-Text 'feed.xml' $rss.ToString()

    Write-Host '  sitemap.xml · feed.xml 생성'
} else {
    Write-Host '  sitemap.xml · feed.xml 건너뜀 (sources.json 의 baseUrl 이 비어 있음)' -ForegroundColor DarkYellow
}

Write-Host ''
Write-Host "  완료 — $outPath" -ForegroundColor Green
Write-Host '  미리보기 :  .\serve.ps1' -ForegroundColor Green
Write-Host ''
