// =========================================================
//  비트뉴스 — 화면 움직임
//
//  1) 주요 뉴스 슬라이드 (좌우 화살표 + 5초마다 자동 넘김)
//  2) 최신 / 인기 / 주간 탭 전환
//  3) 트렌딩 나우 목록이 4초마다 한 칸씩 위로 올라감
//
//  속보 띠가 흘러가는 것은 JavaScript 가 아니라 CSS 애니메이션입니다.
//  (style.css 의 ticker-scroll 부분)
// =========================================================

(function () {
  'use strict';

  // 사용자가 기기에서 "화면 움직임 줄이기"를 켜두었으면 자동 넘김을 하지 않습니다
  var reduceMotion = window.matchMedia &&
                     window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // -------------------------------------------------------
  //  1) 주요 뉴스 슬라이드
  // -------------------------------------------------------
  function initSlider() {
    var slider = document.querySelector('[data-slider]');
    if (!slider) return;

    var track = slider.querySelector('.slides');
    var slides = slider.querySelectorAll('.slide');
    var dots = slider.querySelectorAll('.slider-dots button');
    if (slides.length < 2) return;

    var index = 0;
    var timer = null;

    function show(i) {
      // 끝에서 다음을 누르면 처음으로, 처음에서 이전을 누르면 끝으로 돌아갑니다
      index = (i + slides.length) % slides.length;
      track.style.transform = 'translateX(' + (-index * 100) + '%)';

      for (var d = 0; d < dots.length; d++) {
        if (d === index) {
          dots[d].classList.add('is-active');
        } else {
          dots[d].classList.remove('is-active');
        }
      }
    }

    function start() {
      if (reduceMotion) return;
      stop();
      timer = setInterval(function () { show(index + 1); }, 5000);
    }
    function stop() {
      if (timer) { clearInterval(timer); timer = null; }
    }

    // 화살표 버튼
    var prev = document.querySelector('[data-slide="prev"]');
    var next = document.querySelector('[data-slide="next"]');
    if (prev) prev.addEventListener('click', function () { show(index - 1); start(); });
    if (next) next.addEventListener('click', function () { show(index + 1); start(); });

    // 아래 점을 누르면 그 기사로 바로 갑니다
    for (var d = 0; d < dots.length; d++) {
      (function (n) {
        dots[n].addEventListener('click', function () { show(n); start(); });
      })(d);
    }

    // 마우스를 올린 동안에는 넘어가지 않게 해서 읽을 시간을 줍니다
    slider.addEventListener('mouseenter', stop);
    slider.addEventListener('mouseleave', start);

    show(0);
    start();
  }

  // -------------------------------------------------------
  //  2) 최신 / 인기 / 주간 탭
  // -------------------------------------------------------
  function initTabs() {
    var tabs = document.querySelectorAll('.tab');
    if (!tabs.length) return;

    for (var i = 0; i < tabs.length; i++) {
      tabs[i].addEventListener('click', function () {
        var name = this.getAttribute('data-tab');

        var all = document.querySelectorAll('.tab');
        for (var j = 0; j < all.length; j++) all[j].classList.remove('is-active');
        this.classList.add('is-active');

        var panels = document.querySelectorAll('[data-panel]');
        for (var k = 0; k < panels.length; k++) {
          if (panels[k].getAttribute('data-panel') === name) {
            panels[k].classList.add('is-active');
          } else {
            panels[k].classList.remove('is-active');
          }
        }
      });
    }
  }

  // -------------------------------------------------------
  //  3) 트렌딩 나우 — 한 칸씩 위로 올라감
  //
  //  맨 위 기사를 위로 밀어 올린 뒤, 그 기사를 목록 맨 끝으로 옮기고
  //  위치를 되돌립니다. 그래서 끝없이 도는 것처럼 보입니다.
  // -------------------------------------------------------
  function initRank() {
    var box = document.querySelector('[data-rank-list]');
    if (!box) return;

    var list = box.querySelector('.rank-list');
    if (!list || list.children.length < 2) return;

    var busy = false;
    var timer = null;

    function slideNext() {
      if (busy) return;
      busy = true;

      var first = list.children[0];
      var h = first.getBoundingClientRect().height;

      list.style.transition = 'margin-top 0.5s ease';
      list.style.marginTop = (-h) + 'px';

      window.setTimeout(function () {
        // 애니메이션을 끄고 순간적으로 자리를 바꿉니다 (깜빡임 방지)
        list.style.transition = 'none';
        list.style.marginTop = '0px';
        list.appendChild(first);
        // 브라우저가 위 변경을 반영하도록 한 박자 쉰 뒤 애니메이션을 되살립니다
        window.setTimeout(function () { busy = false; }, 20);
      }, 500);
    }

    function slidePrev() {
      if (busy) return;
      busy = true;

      var last = list.children[list.children.length - 1];
      list.insertBefore(last, list.children[0]);

      var h = last.getBoundingClientRect().height;
      list.style.transition = 'none';
      list.style.marginTop = (-h) + 'px';

      window.setTimeout(function () {
        list.style.transition = 'margin-top 0.5s ease';
        list.style.marginTop = '0px';
        window.setTimeout(function () { busy = false; }, 520);
      }, 20);
    }

    function start() {
      if (reduceMotion) return;
      stop();
      timer = setInterval(slideNext, 4000);
    }
    function stop() {
      if (timer) { clearInterval(timer); timer = null; }
    }

    var up = document.querySelector('[data-rank="prev"]');
    var down = document.querySelector('[data-rank="next"]');
    if (up) up.addEventListener('click', function () { slidePrev(); start(); });
    if (down) down.addEventListener('click', function () { slideNext(); start(); });

    box.addEventListener('mouseenter', stop);
    box.addEventListener('mouseleave', start);

    start();
  }

  // -------------------------------------------------------
  //  4) 썸네일이 깨졌을 때 ₿ 자리표시로 바꾸기
  //
  //  뉴스 썸네일은 우리 서버에 사본이 없습니다. 언론사 서버
  //  (f1.tokenpost.kr · cdn.blockmedia.co.kr)에서 바로 불러옵니다.
  //  상대가 사진을 지우거나 주소를 바꾸면 깨진 이미지 아이콘이 그대로 보입니다.
  //  기사에 원래 사진이 없을 때 쓰는 ₿ 표시로 바꿔 끼웁니다.
  //
  //  ⚠️ img 의 error 는 위로 전파되지 않습니다(버블링이 없습니다).
  //     그래서 addEventListener 의 세 번째 인자를 true 로 주어
  //     내려가는 단계(캡처)에서 잡습니다. 이걸 빼면 아무것도 안 잡힙니다.
  //
  //  ⚠️ 이 스크립트는 </body> 바로 앞에서 실행됩니다. 그때는 이미
  //     실패가 끝난 이미지가 있을 수 있어 듣기만 해서는 놓칩니다.
  //     그래서 한 번 훑어보는 단계를 같이 둡니다.
  // -------------------------------------------------------
  function replaceBrokenImage(img) {
    if (!img || img.dataset.fallbackDone) { return; }
    img.dataset.fallbackDone = '1';

    var el = null;
    if (img.classList.contains('slide-img')) {
      el = document.createElement('div');
      el.className = 'slide-img slide-img-empty';
    } else if (img.classList.contains('card-thumb')) {
      el = document.createElement('div');
      el.className = 'card-thumb-empty';
    } else if (img.closest('.mini-thumb')) {
      el = document.createElement('span');
      el.className = 'mini-thumb-empty';
    } else if (img.closest('.ticker-item')) {
      el = document.createElement('span');
      el.className = 'ticker-thumb-empty';
    }

    // 기사 본문의 큰 사진(article-thumb)에는 자리표시가 없습니다.
    // 억지로 만들지 않고 그냥 뺍니다 — 사진 없는 기사와 같은 모습이 됩니다.
    if (!el) {
      if (img.parentNode) { img.parentNode.removeChild(img); }
      return;
    }

    el.textContent = '₿';
    if (img.parentNode) { img.parentNode.replaceChild(el, img); }
  }

  function initImageFallback() {
    document.addEventListener('error', function (e) {
      var t = e.target;
      if (t && t.tagName === 'IMG') { replaceBrokenImage(t); }
    }, true);

    // 이미 실패가 끝난 것 줍기
    // (complete 가 true 인데 naturalWidth 가 0 이면 못 불러온 것입니다)
    var imgs = document.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      if (imgs[i].complete && imgs[i].naturalWidth === 0) {
        replaceBrokenImage(imgs[i]);
      }
    }
  }

  // 페이지가 다 그려진 뒤에 시작합니다
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      initSlider(); initTabs(); initRank(); initImageFallback();
    });
  } else {
    initSlider(); initTabs(); initRank(); initImageFallback();
  }
})();
