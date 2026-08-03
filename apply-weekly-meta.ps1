# =========================================================
#  비트뉴스 — 주간 정리 목차에 새 글 등록
#
#  Claude 가 만들어 둔 weekly\.work\meta.json 을 읽어
#  weekly\weekly.json 의 posts 목록 맨 위에 한 덩어리를 끼워 넣습니다.
#
#  통째로 다시 쓰지 않고 글자를 찾아 그 자리에만 넣습니다.
#  그래야 파일 안의 설명 주석이 사라지지 않습니다.
#
#  쓰는 법 : .\apply-weekly-meta.ps1 -Slug 2026-08-w2 -From 2026-08-04 -To 2026-08-10
# =========================================================

param(
    [Parameter(Mandatory=$true)][string]$Slug,
    [Parameter(Mandatory=$true)][string]$From,
    [Parameter(Mandatory=$true)][string]$To
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$metaPath = Join-Path (Join-Path (Join-Path $root 'weekly') '.work') 'meta.json'
if (-not (Test-Path $metaPath)) {
    throw "weekly\.work\meta.json 이 없습니다. Claude 가 글을 만들지 못한 것 같습니다."
}
$meta = (Get-Content $metaPath -Raw -Encoding UTF8) | ConvertFrom-Json

foreach ($f in 'title','subtitle','desc') {
    if ([string]::IsNullOrWhiteSpace($meta.$f)) { throw "meta.json 의 $f 가 비어 있습니다." }
}

$postPath = Join-Path (Join-Path (Join-Path $root 'weekly') 'posts') ($Slug + '.html')
if (-not (Test-Path $postPath)) { throw "본문 파일이 없습니다: weekly\posts\$Slug.html" }
$bodyLen = (Get-Content $postPath -Raw -Encoding UTF8).Length
if ($bodyLen -lt 800) { throw "본문이 너무 짧습니다($bodyLen 자). 제대로 만들어지지 않은 것 같습니다." }

# JSON 문자열 안에 넣을 수 있게 특수문자를 처리합니다
function Escape-Json {
    param([string]$s)
    return ($s -replace '\\', '\\' -replace '"', '\"' -replace "`r", '' -replace "`n", ' ')
}

$entry = @"

    {
      "slug": "$Slug",
      "title": "$(Escape-Json $meta.title)",
      "subtitle": "$(Escape-Json $meta.subtitle)",
      "desc": "$(Escape-Json $meta.desc)",
      "from": "$From",
      "to": "$To",
      "published": "$To"
    },
"@

$cfgPath = Join-Path (Join-Path $root 'weekly') 'weekly.json'
$cfgText = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)

if ($cfgText -match [regex]::Escape("`"slug`": `"$Slug`"")) {
    Write-Host "  이미 목차에 있는 글입니다. 그대로 둡니다." -ForegroundColor DarkYellow
    exit 0
}

$marker = '"posts": ['
$idx = $cfgText.IndexOf($marker)
if ($idx -lt 0) { throw "weekly.json 에서 `"posts`": [ 를 찾지 못했습니다." }
$cfgText = $cfgText.Insert($idx + $marker.Length, $entry)

# 넣은 뒤 JSON 이 깨지지 않았는지 확인하고 저장합니다
try { $null = $cfgText | ConvertFrom-Json } catch { throw "weekly.json 이 깨졌습니다: $($_.Exception.Message)" }
[System.IO.File]::WriteAllText($cfgPath, $cfgText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host '  목차에 등록했습니다' -ForegroundColor Green
Write-Host ("    제목 : {0}" -f $meta.title)
Write-Host ("    부제 : {0}" -f $meta.subtitle)
Write-Host ("    본문 : {0:N0}자" -f $bodyLen)
if ($meta.verified) {
    Write-Host ''
    Write-Host '  Claude 가 확인했다고 밝힌 수치:'
    foreach ($v in @($meta.verified)) { Write-Host ("    · {0}" -f $v) }
}
Write-Host ''
