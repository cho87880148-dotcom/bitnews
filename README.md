# 비트뉴스

비트코인·암호화폐 뉴스를 언론사 RSS에서 자동으로 모아 보여주는 사이트입니다.

---

## 폴더 안내

내가 **고쳐도 되는 것**

| 파일 | 무엇을 바꾸나 |
|---|---|
| `sources.json` | 뉴스 출처, 사이트 이름, 도메인 주소, 걸러낼 키워드 |
| `assets/css/style.css` | 색·글꼴·간격 (맨 위 `:root` 값만 고치면 전체에 반영) |
| `templates/base.html` | 머리말·꼬리말 등 모든 페이지 공통 틀 |

**건드리면 안 되는 것**

| 폴더 | 이유 |
|---|---|
| `dist/` | `build.ps1` 이 실행될 때마다 통째로 새로 만듭니다. 여기서 고친 것은 다음 실행 때 사라집니다 |
| `data/articles.json` | 지금까지 모은 기사 목록입니다. 지우면 예전 기사 페이지가 전부 사라집니다 |

---

## 내 PC에서 쓰는 법

```powershell
.\build.ps1     # 뉴스를 모아 dist 폴더에 사이트를 만듭니다
.\serve.ps1     # 만들어진 사이트를 미리 봅니다 → http://localhost:8080
```

`serve.ps1` 은 Ctrl+C 로 끕니다.

---

## 자주 하는 조정

**기사가 너무 적을 때 / 관련 없는 기사가 섞일 때**

`sources.json` 의 `keywords` 목록을 늘리거나 줄입니다.
이 낱말이 제목이나 요약에 하나라도 있으면 사이트에 실립니다.

**영어 기사도 넣고 싶을 때**

`sources.json` 에서 Cointelegraph 등의 `"enabled": false` 를 `true` 로 바꿉니다.
제목이 영어 그대로 나오니 감안하세요.

**한 페이지에 보이는 기사 수를 바꿀 때**

```powershell
.\build.ps1 -PerPage 20
```

---

## GitHub에 올려 자동 갱신하기 (아직 안 한 단계)

이걸 하면 **내 PC가 꺼져 있어도** 1시간마다 뉴스가 자동으로 갱신됩니다.
아래 순서대로 한 번만 하면 됩니다.

**1) GitHub 가입 및 저장소 만들기**
- <https://github.com> 가입
- 오른쪽 위 `+` → `New repository`
- 이름은 아무거나 (예: `bitnews`), **Public** 선택, 나머지는 그대로 두고 생성

**2) 이 폴더를 올리기**

생성된 저장소 화면에 나오는 주소를 복사한 뒤, 이 폴더에서:

```powershell
git init
git add .
git commit -m "비트뉴스 첫 커밋"
git branch -M main
git remote add origin <복사한 주소>
git push -u origin main
```

> `git` 이 없다는 오류가 나오면 <https://git-scm.com/download/win> 에서 설치 후 다시 하세요.

**3) GitHub Pages 켜기**
- 저장소 → `Settings` → 왼쪽 `Pages`
- `Source` 를 **GitHub Actions** 로 선택

**4) 확인**
- 저장소 → `Actions` 탭에 "뉴스 자동 수집" 이 돌고 있습니다
- 초록색 체크가 뜨면 완료. 주소는 `https://<내아이디>.github.io/bitnews/` 입니다

**5) 주소를 `sources.json` 에 적기**

위에서 확인한 주소를 `sources.json` 의 `baseUrl` 에 넣고 다시 올립니다.

```json
"baseUrl": "https://내아이디.github.io/bitnews"
```

이걸 해야 `sitemap.xml` 과 `feed.xml` 이 만들어지고 검색엔진에 등록할 수 있습니다.
(비워두면 이 두 파일은 생성되지 않고, 나머지는 정상 동작합니다.)

---

## 저작권에 대해

이 사이트는 각 언론사가 **공개한 RSS**에서 제목과 요약만 가져옵니다.
기사 본문은 싣지 않고, 각 기사 페이지의 "원문 전체 보기" 버튼으로 원래 언론사에 보냅니다.
출처명도 모든 기사에 표시됩니다.

`build.ps1` 을 고쳐 본문 전체를 가져오는 것은 **저작권 침해**이고,
구글도 복제한 내용으로 판단해 검색에서 제외합니다. 하지 마세요.

검색 노출을 늘리고 싶다면 기사마다 직접 쓴 한두 문단(내 해석, 배경 설명)을 덧붙이는 쪽이
안전하고 효과도 큽니다.
