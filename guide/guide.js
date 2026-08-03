// =========================================================
//  바이낸스 가이드 — 화면 동작
//  1) 왼쪽 목차 검색  2) 좁은 화면에서 목차 펼치기  3) 추천코드 복사
// =========================================================
(function () {
  'use strict';

  // 1) 목차 검색 — 입력한 글자가 들어간 항목만 남깁니다
  var search = document.querySelector('[data-guide-search]');
  if (search) {
    search.addEventListener('input', function () {
      var q = this.value.trim().toLowerCase();
      var items = document.querySelectorAll('.g-toc li');
      for (var i = 0; i < items.length; i++) {
        var text = items[i].textContent.toLowerCase();
        if (q === '' || text.indexOf(q) !== -1) {
          items[i].classList.remove('is-hidden');
        } else {
          items[i].classList.add('is-hidden');
        }
      }
    });
  }

  // 2) 좁은 화면에서 목차 열고 닫기
  var toggle = document.querySelector('[data-toc-toggle]');
  var side = document.querySelector('[data-toc]');
  if (toggle && side) {
    toggle.addEventListener('click', function () {
      side.classList.toggle('is-open');
    });
  }

  // 3) 추천코드 복사
  // 클립보드 기능은 http://localhost 나 https 에서만 동작합니다.
  // 파일을 더블클릭해서 연 경우(file:///)에는 막히므로 예전 방식으로 대체합니다.
  var copyBtns = document.querySelectorAll('[data-copy]');
  for (var b = 0; b < copyBtns.length; b++) {
    copyBtns[b].addEventListener('click', function () {
      var value = this.getAttribute('data-copy');
      var btn = this;
      var done = function () {
        var old = btn.textContent;
        btn.textContent = '복사됨';
        setTimeout(function () { btn.textContent = old; }, 1500);
      };

      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(value).then(done, function () { fallback(value, done); });
      } else {
        fallback(value, done);
      }
    });
  }

  function fallback(value, done) {
    var ta = document.createElement('textarea');
    ta.value = value;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); done(); } catch (e) { }
    document.body.removeChild(ta);
  }
})();
