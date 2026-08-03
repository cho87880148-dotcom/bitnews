# =========================================================
#  비트뉴스 — 주간 정리 초고 자동 생성 (Claude API 사용)
#
#  하는 일:
#    1. data/articles.json 에서 지난 7일 기사를 꺼냅니다
#    2. 그 기사들과 "1주차 글"을 본보기로 함께 Claude 에 보냅니다
#    3. 돌아온 글을 weekly/posts/<slug>.html 로 저장하고
#       weekly/weekly.json 목록 맨 위에 한 줄 추가합니다
#
#  ※ 이 스크립트는 글을 만들기만 합니다. 발행하지 않습니다.
#     GitHub Actions 가 이걸 돌린 뒤 "검토 요청(Pull Request)"으로 올려두고,
#     사람이 승인해야 사이트에 올라갑니다.
#
#  쓰는 법 (내 PC 에서 시험할 때):
#    $env:ANTHROPIC_API_KEY = 'sk-ant-...'
#    .\generate-weekly.ps1
#
#  옵션:
#    -Days 14        지난 14일로 범위 넓히기
#    -Slug 2026-08-w3  파일 이름 직접 지정
#    -DryRun         API 만 호출하고 파일은 쓰지 않음 (결과를 화면에 보여줌)
# =========================================================

param(
    [int]$Days = 7,
    [string]$Slug = '',
    [switch]$DryRun,
    [string]$Model = 'claude-opus-5',
    [int]$MaxTokens = 32000
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$root = $PSScriptRoot

$apiKey = $env:ANTHROPIC_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw "ANTHROPIC_API_KEY 가 없습니다. GitHub 에서는 Secret 으로, 내 PC 에서는 `$env:ANTHROPIC_API_KEY 로 넣어주세요."
}

function ConvertTo-Utc {
    param([string]$Iso)
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
              [System.Globalization.DateTimeStyles]::AssumeUniversal
    return [datetime]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
}

# ---------------------------------------------------------
#  1. 이번 주 기사 모으기
# ---------------------------------------------------------
$storePath = Join-Path (Join-Path $root 'data') 'articles.json'
if (-not (Test-Path $storePath)) { throw "data\articles.json 이 없습니다. 먼저 .\build.ps1 을 실행하세요." }
$all = (Get-Content $storePath -Raw -Encoding UTF8) | ConvertFrom-Json

$nowUtc  = (Get-Date).ToUniversalTime()
$fromUtc = $nowUtc.AddDays(-$Days)
$week = @($all |
    Where-Object { (ConvertTo-Utc $_.published) -ge $fromUtc } |
    Sort-Object { (ConvertTo-Utc $_.published) } -Descending)

if ($week.Count -lt 10) { throw ("최근 {0}일 기사가 {1}건뿐입니다. 글을 쓰기엔 부족합니다." -f $Days, $week.Count) }

$fromKst = $fromUtc.AddHours(9)
$toKst   = $nowUtc.AddHours(9)
if (-not $Slug) {
    $weekNo = [math]::Ceiling($toKst.Day / 7.0)
    $Slug = '{0:yyyy-MM}-w{1}' -f $toKst, $weekNo
}

Write-Host ''
Write-Host '  주간 정리 초고 생성' -ForegroundColor Yellow
Write-Host ("  기간 : {0:yyyy-MM-dd} ~ {1:yyyy-MM-dd}" -f $fromKst, $toKst)
Write-Host ("  기사 : {0}건" -f $week.Count)
Write-Host ("  파일 : weekly\posts\{0}.html" -f $Slug)
Write-Host ("  모델 : {0}" -f $Model)
Write-Host ''

$postPath = Join-Path (Join-Path (Join-Path $root 'weekly') 'posts') ($Slug + '.html')
if ((Test-Path $postPath) -and -not $DryRun) {
    Write-Host ("  이미 있는 글입니다. 덮어쓰지 않고 끝냅니다: {0}" -f $Slug) -ForegroundColor DarkYellow
    exit 0
}

# 기사 목록을 글감으로 정리합니다. id 를 함께 줘서 본문에서 링크를 걸 수 있게 합니다.
$sb = New-Object System.Text.StringBuilder
foreach ($a in $week) {
    $kst = (ConvertTo-Utc $a.published).AddHours(9)
    $sum = $a.summary
    if ($sum.Length -gt 300) { $sum = $sum.Substring(0, 300) + '…' }
    [void]$sb.AppendLine(('[{0:MM-dd HH:mm}] ({1}) id={2}' -f $kst, $a.source, $a.id))
    [void]$sb.AppendLine(('제목: {0}' -f $a.title))
    [void]$sb.AppendLine(('요약: {0}' -f $sum))
    [void]$sb.AppendLine('')
}
$articleBlock = $sb.ToString()

# 앞서 사람이 쓴 1주차 글을 본보기로 함께 보냅니다. 형식이 흔들리지 않게 하는 가장 확실한 방법입니다.
$examplePath = Join-Path (Join-Path (Join-Path $root 'weekly') 'posts') '2026-08-w1.html'
$example = ''
if (Test-Path $examplePath) { $example = Get-Content $examplePath -Raw -Encoding UTF8 }

# ---------------------------------------------------------
#  2. Claude 에게 보낼 지시문
# ---------------------------------------------------------
$system = @'
당신은 한국어 비트코인 뉴스 사이트 "비트뉴스"의 주간 정리 기사를 쓰는 편집자입니다.

가장 중요한 규칙 — 반드시 지킬 것:
1. 아래 제공된 기사 목록에 실제로 나오는 사실과 숫자만 사용하십시오.
   목록에 없는 가격, 날짜, 인물, 수치, 사건을 절대 지어내지 마십시오.
   기억이나 일반 지식으로 숫자를 보충하지 마십시오.
2. 숫자를 쓸 때는 그 숫자가 나온 기사의 표현을 그대로 따르십시오.
   여러 기사가 서로 다른 값을 말하면 둘 다 쓰거나 범위로 표현하고, 임의로 하나를 고르지 마십시오.
3. 인과관계를 단정하지 마십시오. 기사가 "~때문으로 풀이된다"고 하면 그 수준으로만 쓰십시오.
4. 투자 조언, 매수/매도 권유, 가격 예측을 하지 마십시오.
5. 확실하지 않으면 쓰지 마십시오. 분량보다 정확성이 우선입니다.

글의 성격:
- 독자는 비트코인을 잘 모르는 한국 일반인입니다. 전문용어는 풀어서 설명하십시오.
- 사실 나열이 아니라 "그래서 이게 왜 중요한가"를 짚어주는 글입니다.
- 담백하고 차분한 문체. 과장, 감탄, 이모지를 쓰지 마십시오.

출력 형식:
- body_html 은 <body> 안에 들어갈 조각입니다. <html>, <head>, <h1> 을 쓰지 마십시오(제목은 따로 만들어집니다).
- 아래 CSS 클래스만 사용하십시오:
  <p class="wk-lead">        도입부 한 문단
  <div class="wk-summary"><h2>이번 주 세 줄 요약</h2><ul><li>…</li></ul></div>
  <section class="wk-sec"><h2>제목</h2><p>…</p></section>   본문 섹션 (3~5개)
  <h3>소제목</h3>                                            섹션 안 소제목
  <ul class="wk-list"><li>…</li></ul>                        목록
  <div class="wk-note"><strong>제목</strong><br />…</div>     초보자 설명 상자
  <div class="wk-note wk-note--warn">…</div>                 주의 상자
  <div class="wk-table-wrap"><table class="wk-table"><thead>…</thead><tbody>…</tbody></table></div>
- 마지막 섹션은 반드시 <h2>다음 주에 볼 것</h2> 으로 하고 관전 포인트 3~4개를 <ul class="wk-list"> 로 씁니다.
- 맨 끝에 아래 고지를 그대로 붙이십시오:
  <div class="wk-disclaimer"><p>이 글은 한 주간 보도된 내용을 정리한 것으로, <strong>투자 권유가 아닙니다.</strong> 가상자산은 가격 변동성이 크고 원금 손실 가능성이 있습니다. 수치는 각 매체가 보도한 시점 기준이며 실시간 시세와 다를 수 있습니다. 투자 판단과 그 결과에 대한 책임은 본인에게 있습니다.</p></div>
- 핵심 사실 3~6곳에 근거 기사 링크를 <a href="../news/기사id.html">…</a> 형태로 다십시오. id 는 제공된 목록의 id 값입니다.

제목(title) 규칙:
- 그 주의 핵심 사건을 앞에 씁니다. "8월 2주차 요약" 같은 제목은 절대 쓰지 마십시오.
- 40자 안쪽. 숫자를 하나 넣으면 좋습니다.
- 좋은 예: "비트코인 6만2천달러 후퇴, 콜드카드 8800만 달러 피해"
'@

$userPrompt = @"
아래는 $($fromKst.ToString('yyyy년 M월 d일')) ~ $($toKst.ToString('M월 d일')) 사이에 보도된 기사 $($week.Count)건입니다.
이 내용만 근거로 주간 정리 기사를 작성해 주십시오.

===== 이번 주 기사 목록 =====
$articleBlock
===== 기사 목록 끝 =====

참고로, 지난주에 사람이 직접 쓴 글의 본문입니다. 형식·문체·깊이를 이 수준으로 맞춰 주십시오.
(내용을 베끼지 말고 형식만 참고하십시오. 이번 주 기사에 근거해 새로 쓰십시오.)

===== 지난주 글 (형식 본보기) =====
$example
===== 본보기 끝 =====

subtitle 은 다음 형식으로 만드십시오:
"$($toKst.ToString('yyyy년 M월'))  비트코인 정리 ($($fromKst.ToString('M월 d일')) ~ $($toKst.ToString('M월 d일')))"
— 단, 앞의 두 칸 공백은 넣지 말고 자연스럽게 쓰십시오.

desc 는 검색 결과에 나올 설명입니다. 155자 안쪽으로, 그 주의 핵심 사실을 담아 쓰십시오.
"@

# ---------------------------------------------------------
#  3. Claude API 호출
#
#  output_config.format 으로 응답 형식을 JSON 으로 못박습니다.
#  이렇게 하면 글자를 잘라내며 파싱할 필요가 없어 훨씬 안전합니다.
# ---------------------------------------------------------
$schema = [ordered]@{
    type = 'object'
    properties = [ordered]@{
        title     = [ordered]@{ type = 'string'; description = '핵심 사건을 앞세운 기사 제목. 40자 안쪽.' }
        subtitle  = [ordered]@{ type = 'string'; description = '부제. 몇 년 몇 월 정리 + 기간.' }
        desc      = [ordered]@{ type = 'string'; description = '검색 결과용 설명. 155자 안쪽.' }
        body_html = [ordered]@{ type = 'string'; description = '본문 HTML 조각.' }
    }
    required = @('title', 'subtitle', 'desc', 'body_html')
    additionalProperties = $false
}

$body = [ordered]@{
    model      = $Model
    max_tokens = $MaxTokens
    system     = $system
    messages   = @( [ordered]@{ role = 'user'; content = $userPrompt } )
    output_config = [ordered]@{
        effort = 'high'
        format = [ordered]@{ type = 'json_schema'; schema = $schema }
    }
    # 안전 분류기가 요청을 거절하면 다른 모델이 대신 답하도록 합니다.
    # 암호화폐 글에서 걸릴 일은 드물지만, 걸렸을 때 그냥 실패하는 것보다 낫습니다.
    fallbacks = 'default'
}

$json = $body | ConvertTo-Json -Depth 12 -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

Write-Host ("  Claude 에 보냅니다... (보내는 글자 수 {0:N0})" -f $userPrompt.Length)

$req = [System.Net.HttpWebRequest]::Create('https://api.anthropic.com/v1/messages')
$req.Method = 'POST'
$req.ContentType = 'application/json'
$req.Headers.Add('x-api-key', $apiKey)
$req.Headers.Add('anthropic-version', '2023-06-01')
$req.Headers.Add('anthropic-beta', 'server-side-fallback-2026-07-01')
$req.Timeout = 900000           # 15분. 글이 길어 오래 걸릴 수 있습니다.
$req.ReadWriteTimeout = 900000
$req.ContentLength = $bytes.Length

$stream = $req.GetRequestStream()
$stream.Write($bytes, 0, $bytes.Length)
$stream.Close()

try {
    $res = $req.GetResponse()
} catch [System.Net.WebException] {
    $errBody = ''
    if ($_.Exception.Response) {
        $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $errBody = $sr.ReadToEnd(); $sr.Close()
    }
    throw ("Claude API 호출 실패: {0}`n{1}" -f $_.Exception.Message, $errBody)
}

$sr = New-Object System.IO.StreamReader($res.GetResponseStream(), [System.Text.Encoding]::UTF8)
$raw = $sr.ReadToEnd(); $sr.Close(); $res.Close()
$resp = $raw | ConvertFrom-Json

# ---------------------------------------------------------
#  4. 응답 점검
# ---------------------------------------------------------
Write-Host ("  응답 받음 — 모델 {0}, 종료사유 {1}" -f $resp.model, $resp.stop_reason)
if ($resp.usage) {
    Write-Host ("  토큰 사용 — 입력 {0:N0} / 출력 {1:N0}" -f $resp.usage.input_tokens, $resp.usage.output_tokens)
    $cost = ($resp.usage.input_tokens / 1e6 * 5) + ($resp.usage.output_tokens / 1e6 * 25)
    Write-Host ("  이번 호출 비용 약 {0:N3} USD" -f $cost)
}

if ($resp.stop_reason -eq 'refusal') {
    throw "안전 분류기가 이 요청을 거절했습니다. 기사 내용에 민감한 주제가 섞였을 수 있습니다. 사람이 직접 확인해 주세요."
}
if ($resp.stop_reason -eq 'max_tokens') {
    throw "글이 max_tokens($MaxTokens) 한도에서 잘렸습니다. -MaxTokens 를 올려 다시 실행하세요."
}

$textBlock = @($resp.content | Where-Object { $_.type -eq 'text' }) | Select-Object -First 1
if (-not $textBlock) { throw "응답에 본문이 없습니다. 원본 응답:`n$raw" }

$post = $textBlock.text | ConvertFrom-Json

foreach ($f in 'title','subtitle','desc','body_html') {
    if ([string]::IsNullOrWhiteSpace($post.$f)) { throw "응답에 $f 가 비어 있습니다." }
}

Write-Host ''
Write-Host '  ---- 생성된 글 ----' -ForegroundColor Green
Write-Host ("  제목 : {0}" -f $post.title)
Write-Host ("  부제 : {0}" -f $post.subtitle)
Write-Host ("  설명 : {0}" -f $post.desc)
Write-Host ("  본문 : {0:N0}자" -f $post.body_html.Length)
Write-Host ''

if ($DryRun) {
    Write-Host '  (연습 모드 — 파일을 쓰지 않았습니다)' -ForegroundColor DarkYellow
    Write-Host $post.body_html
    return
}

# ---------------------------------------------------------
#  5. 파일로 저장
# ---------------------------------------------------------
$postsDir = Split-Path $postPath -Parent
if (-not (Test-Path $postsDir)) { New-Item -ItemType Directory -Force -Path $postsDir | Out-Null }
[System.IO.File]::WriteAllText($postPath, $post.body_html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("  저장: weekly\posts\{0}.html" -f $Slug) -ForegroundColor Green

# weekly.json 의 posts 목록 맨 위에 끼워 넣습니다.
# 통째로 다시 만들면 설명 주석이 사라지므로, 글자를 찾아 그 자리에만 넣습니다.
function Escape-Json { param([string]$s) return ($s -replace '\\', '\\' -replace '"', '\"' -replace "`r", '' -replace "`n", ' ') }

$cfgPath = Join-Path (Join-Path $root 'weekly') 'weekly.json'
$cfgText = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)

$entry = @"

    {
      "slug": "$Slug",
      "title": "$(Escape-Json $post.title)",
      "subtitle": "$(Escape-Json $post.subtitle)",
      "desc": "$(Escape-Json $post.desc)",
      "from": "$($fromKst.ToString('yyyy-MM-dd'))",
      "to": "$($toKst.ToString('yyyy-MM-dd'))",
      "published": "$($toKst.ToString('yyyy-MM-dd'))"
    },
"@

$marker = '"posts": ['
$idx = $cfgText.IndexOf($marker)
if ($idx -lt 0) { throw "weekly.json 에서 `"posts`": [ 를 찾지 못했습니다." }
$insertAt = $idx + $marker.Length
$cfgText = $cfgText.Insert($insertAt, $entry)
[System.IO.File]::WriteAllText($cfgPath, $cfgText, (New-Object System.Text.UTF8Encoding($false)))

# 넣은 뒤 JSON 이 깨지지 않았는지 확인합니다
try { $null = $cfgText | ConvertFrom-Json } catch { throw "weekly.json 이 깨졌습니다: $($_.Exception.Message)" }

Write-Host '  weekly.json 목록에 추가' -ForegroundColor Green
Write-Host ''
Write-Host '  이제 .\build.ps1 을 실행하면 사이트에 반영됩니다.' -ForegroundColor Green
Write-Host ''
