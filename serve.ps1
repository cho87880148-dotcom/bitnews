# =========================================================
#  새 사이트 — 로컬 미리보기 서버
#
#  왜 필요한가?
#   index.html 을 더블클릭해서 열면 주소가 file:/// 로 시작합니다.
#   브라우저는 이 상태를 "웹사이트"로 취급하지 않아서 일부 기능
#   (클립보드 복사 등)이 막힙니다.
#   http://localhost 로 띄우면 실제 배포된 것과 똑같은 환경이 됩니다.
#
#  쓰는 법 : .\serve.ps1
#  끄는 법 : 이 창에서 Ctrl+C
# =========================================================

param(
    [int]$Port = 8080,
    [string]$Folder = 'dist'   # build.ps1 이 만들어낸 폴더를 그대로 미리 봅니다
)

$ErrorActionPreference = 'Stop'

$rootPath = Join-Path $PSScriptRoot $Folder
if (-not (Test-Path $rootPath)) {
    Write-Error "$Folder 폴더가 없습니다. 먼저 .\build.ps1 을 실행하세요."
}
$rootPath = (Resolve-Path $rootPath).Path

# 확장자별 파일 종류 알려주기 (브라우저가 해석하는 방식이 달라집니다)
$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.txt'  = 'text/plain; charset=utf-8'
    '.xml'  = 'application/xml; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.webp' = 'image/webp'
    '.ico'  = 'image/x-icon'
    '.woff' = 'font/woff'
    '.woff2' = 'font/woff2'
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")

try {
    $listener.Start()
} catch {
    Write-Error "포트 $Port 를 열 수 없습니다. 이미 다른 프로그램이 쓰고 있을 수 있습니다. 다른 번호로 해보세요:  .\serve.ps1 -Port 8081"
}

Write-Host ""
Write-Host "  로컬 서버 실행 중" -ForegroundColor Green
Write-Host "  주소   : http://localhost:$Port/"
Write-Host "  폴더   : $rootPath"
Write-Host "  끄기   : Ctrl+C"
Write-Host ""

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
    } catch {
        break
    }

    $res = $ctx.Response
    # 주소에서 쿼리(?뒤)를 떼고, %20 같은 인코딩을 원래 글자로 되돌립니다
    $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
    if ($rel -eq '') { $rel = 'index.html' }

    $target = Join-Path $rootPath ($rel -replace '/', '\')

    # 폴더 밖(상위 폴더)으로 빠져나가는 요청은 차단
    $full = [System.IO.Path]::GetFullPath($target)
    if (-not $full.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        $res.StatusCode = 403
        $res.Close()
        continue
    }

    # 폴더를 요청했으면 그 안의 index.html 을 보여줍니다
    if (Test-Path $full -PathType Container) {
        $full = Join-Path $full 'index.html'
    }
    # 확장자 없이 /about 으로 들어와도 about.html 을 찾아줍니다
    if (-not (Test-Path $full -PathType Leaf) -and (Test-Path "$full.html" -PathType Leaf)) {
        $full = "$full.html"
    }

    # HEAD 는 "본문 말고 헤더만 주세요" 라는 요청입니다.
    # 이때 본문을 써 보내면 오류가 나고 서버가 통째로 죽습니다.
    $bodyAllowed = ($ctx.Request.HttpMethod -ne 'HEAD')

    # 요청 하나가 실패해도 서버 전체는 계속 살아있어야 합니다.
    try {
        if (Test-Path $full -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($full).ToLower()
            $type = $mime[$ext]
            if (-not $type) { $type = 'application/octet-stream' }

            $bytes = [System.IO.File]::ReadAllBytes($full)
            $res.ContentType = $type
            $res.Headers.Add('Cache-Control', 'no-store')  # 수정하면 새로고침만으로 바로 반영
            $res.ContentLength64 = $bytes.Length
            if ($bodyAllowed) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
            $status = 200
        } else {
            # 없는 주소면 404.html 을 보여줍니다 (아직 없으면 짧은 문구로 대체)
            $notFound = Join-Path $rootPath '404.html'
            if (Test-Path $notFound -PathType Leaf) {
                $msg = [System.IO.File]::ReadAllBytes($notFound)
            } else {
                $msg = [Text.Encoding]::UTF8.GetBytes("<meta charset='utf-8'><h1>404</h1><p>$rel 파일이 없습니다.</p>")
            }
            $res.StatusCode = 404
            $res.ContentType = 'text/html; charset=utf-8'
            $res.ContentLength64 = $msg.Length
            if ($bodyAllowed) { $res.OutputStream.Write($msg, 0, $msg.Length) }
            $status = 404
        }
    }
    catch {
        # 브라우저가 도중에 연결을 끊는 것은 흔한 일이라 조용히 넘어갑니다
        $status = 'ERR'
    }

    try { $res.Close() } catch { }
    Write-Host ("  {0}  {1}  /{2}" -f (Get-Date -Format 'HH:mm:ss'), $status, $rel)
}

$listener.Stop()
