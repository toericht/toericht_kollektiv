(function () {
  var headerHTML =
    '<header class="topbar">' +
    '<a class="mini-logo" href="index.html#home" aria-label="töricht – Startseite">' +
    '<img src="assets/images/oe.png" alt="">' +
    '</a>' +
    '</header>';

  var footerHTML =
    '<footer>' +
    '<span>©2026 töricht</span>' +
    '<nav class="footer-links" aria-label="rechtliches">' +
    '<a href="impressum.html">impressum</a>' +
    '<span class="dot" aria-hidden="true">·</span>' +
    '<a href="datenschutz.html">datenschutz</a>' +
    '<span class="dot" aria-hidden="true">·</span>' +
    '<a href="https://www.instagram.com/toericht.kollektiv/" target="_blank" rel="noopener noreferrer">instagram<span class="visually-hidden"> (öffnet in neuem Tab)</span></a>' +
    '</nav>' +
    '</footer>';

  var headerEl = document.getElementById('site-header');
  if (headerEl) headerEl.outerHTML = headerHTML;

  var footerEl = document.getElementById('site-footer');
  if (footerEl) footerEl.outerHTML = footerHTML;
})();
