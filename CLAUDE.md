# 비트뉴스 (newhome)

비트코인 뉴스를 언론사 RSS에서 자동 수집해 정적 HTML로 만드는 사이트.
뒤에 `/binance-guide/` 리퍼럴 랜딩 페이지 세트가 붙어 있다.

**이 폴더는 git 저장소가 아니다.** 세션 간 인수인계는 `worklog/YYYY-MM-DD.md` 로 한다.
**새 세션을 시작하면 `worklog/` 의 가장 최근 파일부터 읽을 것.** 거기에 무엇을 왜 했는지,
어디서 막혔는지가 전부 적혀 있다.

> 참고: 옆 폴더 `C:\Users\user\projects\test` 는 **완전히 다른 사이트**(바이낸스 길잡이 /
> bnguide.co.kr)다. 섞지 말 것. 두 폴더 모두 `index.html`, `robots.txt` 를 쓴다.

---

## 사용자에 대해

**개발자가 아니다.** 다른 AI에게 받은 조언을 그대로 붙여넣고 "이게 맞아?" 하고 묻는 패턴이
반복되는데, 그 조언에 사실과 다른 전제가 섞여 있던 적이 실제로 있었다.

- 시키는 대로 고치기 전에 **해당 파일을 직접 읽어 전제가 맞는지 먼저 확인**한다.
- 틀렸으면 "이미 되어 있다 / 사실과 다르다"고 근거(줄 번호, 실측값)와 함께 짧게 알린 뒤 진행한다.
- 설명은 한국어로, 전문용어는 풀어서. 위험한 작업은 왜 위험한지까지 말해준다.

---

## 명령어

```powershell
.\build.ps1      # RSS 수집 → dist\ 에 사이트 전체 생성 (약 10초)
.\serve.ps1      # 미리보기 → http://localhost:8080  (Ctrl+C 로 종료)
.\backfill.ps1   # 과거 기사 채우기. 한 번만 쓰는 것 (아래 설명)
```

---

## 폴더 구조

| 경로 | 무엇 |
|---|---|
| `build.ps1` | 핵심. 수집 → 인기점수 → HTML 생성 전부 |
| `sources.json` | 뉴스 출처·사이트명·키워드·**baseUrl** |
| `templates/base.html` | 뉴스 페이지 공통 껍데기 |
| `assets/css/style.css` | 뉴스 쪽 스타일 (색은 맨 위 `:root`) |
| `assets/js/main.js` | 슬라이드·탭·트렌딩 롤링 |
| `guide/` | 바이낸스 가이드 소스 (`guide.json` + `pages/*.html`) |
| `data/articles.json` | **누적 기사. 지우면 과거 기사 페이지 전부 소멸** |
| `dist/` | 생성 결과물. **직접 고치지 말 것** (매 빌드마다 삭제 후 재생성) |
| `.github/workflows/update.yml` | 1시간마다 자동 수집 → GitHub Pages 배포 |

---

## 반드시 알아야 할 함정

### 1. `.ps1` 은 UTF-8 **BOM** 으로 저장해야 한다
Write 툴은 BOM 없이 쓴다. 그대로 두면 PowerShell 5.1 이 cp949 로 읽어 한글 주석이 깨지고,
**엉뚱한 줄에서** `예기치 않은 '}' 토큰` 파싱 에러가 난다. `.ps1` 을 만들거나 크게 고친 뒤 항상:
```powershell
$t = [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($true)))
```

### 2. `.ps1` 을 정규식으로 일괄 치환하지 말 것
2026-08-03 에 `-replace` 일괄 치환으로 build.ps1 이 **3중 복사되고 285번째 줄에서 잘렸다.**
부분 복구보다 전체를 다시 쓰는 게 빨랐다. 고칠 때는 Edit 로 한 군데씩.

### 3. PowerShell `-eq` 는 대소문자를 안 가린다
PDF 텍스트 추출 때 ASCII85 의 특수기호 `z` 를 `-eq` 로 비교했더니 데이터의 정상 대문자 `Z` 까지
걸려서 디코딩이 통째로 어긋났다. **오류 없이 결과만 0자로 나온다.** 문자 비교는 `-ceq`.

### 4. 서버 정리 명령이 자기 자신을 죽인다
`CommandLine -like '*serve.ps1*'` 로 프로세스를 찾으면, 그 명령을 실행 중인 셸의
CommandLine 에도 그 글자가 들어 있어 자기를 죽인다(exit 255).
반드시 `Where-Object { $_.ProcessId -ne $PID }` 를 넣을 것.

### 5. PowerShell 5.1 과 pwsh 7 양쪽에서 돌아야 한다
GitHub Actions 는 리눅스 pwsh 7 이다. `Join-Path a b c` 는 5.1 에서 안 된다(인자 2개까지).
`Join-Path (Join-Path a b) c` 로 쓸 것.

### 6. 날짜는 `ConvertTo-Utc` 로만 읽을 것
`[datetime]"...Z"` 로 바꾸면 PowerShell 이 한국 시각으로 바꿔버려 UTC 와 빼면 9시간 어긋나고
**모든 기사가 "방금"으로 표시된다.** 이미 한 번 겪었다.

---

## 인기 순위는 진짜 조회수가 아니다

방문자 통계가 없어서 쓸 수 없다. `build.ps1` 5번 구역에서 계산한다:
주제 겹침(최대 40점) + 최신성(48시간 지나면 0, 최대 40점) + 사진 있음(5점).
나중에 애널리틱스를 붙이면 이 부분만 실제 조회수로 바꾸면 된다.

---

## 과거 기사 채우기 (backfill.ps1)

- **RSS 로는 과거 기사를 못 가져온다.** 최신 몇십 건만 준다.
- 블록미디어는 워드프레스라 공개 REST API 로 날짜 지정 수집이 된다. 2026년만 13,650건.
- **토큰포스트는 백필 불가.** `rss?page=2` 가 1페이지와 제목 50건 전부 동일하다.
- `build.ps1` 에 넣지 않았다. 1시간마다 8개월치를 다시 받으면 느리고 상대 서버에도 부담.
- **전부 가져오면 안 된다.** 새 사이트가 갑자기 수천 페이지를 쏟아내면 구글이 스팸으로 본다.

---

## 저작권 원칙 (바꾸지 말 것)

RSS 가 공개한 **제목과 요약만** 쓰고 본문은 싣지 않는다. 각 기사 페이지의
"원문 전체 보기" 로 원 언론사에 보낸다. 출처명도 항상 표시한다.
본문 전체를 긁어오는 것은 저작권 침해이고 구글도 복제 콘텐츠로 판단해 색인에서 뺀다.

가이드의 제휴 링크에는 `rel="noopener nofollow sponsored"` 를 붙이고, 제휴 고지와
투자 위험 안내를 페이지마다 넣는다. **확인되지 않은 할인율(예: "20% 할인")을 CTA 에 쓰지 않는다** —
사용자가 준 PDF 자체가 "할인율은 계정·지역·상품에 따라 다르니 가입 화면에서 확인하라"고 적고 있다.

---

## 현재 상태 (2026-08-03 기준)

**배포 완료. 자동 갱신 가동 중.**

- 사이트: <https://coinfocus.co.kr/> (후이즈에서 산 도메인, 2026-08-03 연결)
  - 옛 주소 `cho87880148-dotcom.github.io/bitnews` 는 301 로 자동 전환된다
  - DNS: 후이즈 → A 레코드 4개(185.199.108~111.153) + www CNAME → `cho87880148-dotcom.github.io`
  - **GitHub Actions 배포에서는 CNAME 파일이 필요 없다.** 저장소 Settings → Pages 의
    Custom domain 설정만 쓰인다 (공식 문서 확인함). 그래서 build.ps1 은 CNAME 을 만들지 않는다.
  - 도메인을 바꾸면 `sources.json` 의 `baseUrl` 도 반드시 함께 바꿀 것
- 저장소: <https://github.com/cho87880148-dotcom/bitnews> (공개)
- 기사 527건 / 목록 44쪽 / 가이드 7쪽 / sitemap 578개 주소
- 리퍼럴: `https://www.binance.com/register?ref=HNEBXFA7` (코드 `HNEBXFA7`)
- GitHub Actions 가 **1시간마다** 수집 → 빌드 → Pages 배포. 실행 #2 에서 전 단계 성공 확인.

### git 관련 주의
- 워크플로가 매 실행마다 `data/articles.json` 을 **저장소에 되돌려 커밋**한다.
  그래서 로컬에서 작업하기 전에 **반드시 `git pull` 부터** 할 것.
  안 하면 push 가 거부되고 `data/articles.json` 충돌이 난다.
- 충돌나면 그 파일은 `git checkout --ours` 로 원격 것을 취하고 `.\build.ps1` 을 다시 돌리면 된다
  (build.ps1 이 링크 기준으로 병합하므로 기사가 사라지지 않는다).
- `.gitattributes` 로 줄바꿈을 LF 로 고정해두었다. 지우지 말 것 —
  CRLF 가 섞이면 리눅스에서 워크플로 셸 명령이 깨진다.

### 검색엔진 등록 — 2026-08-03 완료
- **구글 서치콘솔**: 도메인 속성. 후이즈 DNS 의 **TXT 레코드**로 소유확인
  (`google-site-verification=xW3MX-pIS...`). 도메인 속성이라 http/https/www 를 전부 덮는다.
- **네이버 서치어드바이저**: `templates/base.html` 의 meta 태그로 소유확인
  (`naver-site-verification` = `5b59240f...`). **이 줄을 지우면 소유확인이 풀린다.**
- 양쪽에 `sitemap.xml` 제출, 네이버에는 `feed.xml` 도 RSS 로 제출.

**네이버에서 헤맸던 점 (다시 만나면 바로 알아볼 것):**
- 네이버는 `http://` 와 `https://` 를 **완전히 다른 사이트로** 취급한다.
  http 로 등록해두고 https 주소를 제출하면 `해당 도메인의 URL을 입력해주세요` 오류가 난다.
- 사이트맵과 RSS 는 **메뉴가 다르다.** `사이트맵 제출` 에 feed.xml 을 넣으면 안 된다.
  - 요청 → 사이트맵 제출 → `sitemap.xml`
  - 요청 → RSS 제출 → `feed.xml`

**다음에 할 일 (급하지 않음):**
1. 검색 노출까지 보통 1주~1개월. 그 전에 조바심내고 설정을 건드리지 말 것.
2. **직접 쓴 글을 늘리는 것이 가장 효과적이다.** 지금은 RSS 요약 위주라 한계가 있다.
   기사에 본인 해석을 한두 문단 붙이거나 가이드를 추가하는 방향.
3. 뉴스 출처 추가 — `sources.json` 에서 영어 매체를 켜거나 새 출처 등록
4. 애드센스는 아직 신청하지 말 것 — 요약 위주라 "콘텐츠 불충분"으로 반려될 유형.
   2~3개월 운영 + 직접 쓴 글을 추가한 뒤에 시도할 것
