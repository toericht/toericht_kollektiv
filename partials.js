(function () {
  var file = (window.location.pathname.split('/').pop()) || 'index.html';
  var isEn = /-en\.html$/.test(file);
  var hash = window.location.hash || '';

  var deFile = isEn ? file.replace(/-en\.html$/, '.html') : file;
  var enFile = isEn ? file : file.replace(/\.html$/, '-en.html');

  var t = isEn ? {
    home: 'töricht – home',
    impressum: 'imprint',
    datenschutz: 'privacy policy',
    instagram: 'instagram',
    newTab: ' (opens in new tab)',
    legal: 'legal',
    langLabel: 'switch language'
  } : {
    home: 'töricht – Startseite',
    impressum: 'impressum',
    datenschutz: 'datenschutz',
    instagram: 'instagram',
    newTab: ' (öffnet in neuem Tab)',
    legal: 'rechtliches',
    langLabel: 'sprache wechseln'
  };

  var impressumHref = isEn ? 'impressum-en.html' : 'impressum.html';
  var datenschutzHref = isEn ? 'datenschutz-en.html' : 'datenschutz.html';
  var homeHref = (isEn ? 'index-en.html' : 'index.html') + '#home';

  var headerHTML =
    '<header class="topbar">' +
    '<a class="mini-logo" href="' + homeHref + '" aria-label="' + t.home + '">' +
    '<img src="assets/images/oe.png" alt="">' +
    '</a>' +
    '<nav class="lang-switch" aria-label="' + t.langLabel + '">' +
    '<a href="' + deFile + hash + '"' + (isEn ? '' : ' aria-current="true"') + '>DE</a>' +
    '<span class="lang-sep" aria-hidden="true">/</span>' +
    '<a href="' + enFile + hash + '"' + (isEn ? ' aria-current="true"' : '') + '>EN</a>' +
    '</nav>' +
    '</header>';

  var footerHTML =
    '<footer>' +
    '<span>©2026 töricht</span>' +
    '<nav class="footer-links" aria-label="' + t.legal + '">' +
    '<a href="' + impressumHref + '">' + t.impressum + '</a>' +
    '<span class="dot" aria-hidden="true">·</span>' +
    '<a href="' + datenschutzHref + '">' + t.datenschutz + '</a>' +
    '<span class="dot" aria-hidden="true">·</span>' +
    '<a href="https://www.instagram.com/toericht.kollektiv/" target="_blank" rel="noopener noreferrer">' + t.instagram + '<span class="visually-hidden">' + t.newTab + '</span></a>' +
    '</nav>' +
    '</footer>';

  var headerEl = document.getElementById('site-header');
  if (headerEl) headerEl.outerHTML = headerHTML;

  var footerEl = document.getElementById('site-footer');
  if (footerEl) footerEl.outerHTML = footerHTML;
})();
