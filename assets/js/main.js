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

  // 페이지가 다 그려진 뒤에 시작합니다
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      initSlider(); initTabs(); initRank();
    });
  } else {
    initSlider(); initTabs(); initRank();
  }
})();
