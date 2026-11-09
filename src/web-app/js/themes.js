/* Theme registry. Loaded in <head> so the theme is applied before first paint.

   To add a theme:
     1. Copy css/themes/azure-light.css to css/themes/<id>.css, change the selector to
        [data-theme="<id>"] and the values. Keep every token name.
     2. Add { id, label, href } below.
   The Appearance menu is built from this list. */
var THEMES = [
  { id: 'azure-light',   label: 'Azure light',   href: 'css/themes/azure-light.css' },
  { id: 'azure-dark',    label: 'Azure dark',    href: 'css/themes/azure-dark.css' },
  { id: 'high-contrast', label: 'High contrast', href: 'css/themes/high-contrast.css' }
];
var THEME_KEY = 'igp.theme';
var THEME_DEFAULT_LIGHT = 'azure-light';
var THEME_DEFAULT_DARK = 'azure-dark';

(function loadThemeStylesheets() {
  THEMES.forEach(function (t) {
    var l = document.createElement('link');
    l.rel = 'stylesheet';
    l.href = t.href;
    l.setAttribute('blocking', 'render'); // avoid a flash of unthemed content where supported
    document.head.appendChild(l);
  });
})();

function themeExists(id) { return THEMES.some(function (t) { return t.id === id; }); }

function getSavedTheme() {
  try { return localStorage.getItem(THEME_KEY); } catch (e) { return null; }
}

// A saved choice wins; otherwise follow the operating system's light/dark preference.
function initialTheme() {
  var saved = getSavedTheme();
  if (saved && themeExists(saved)) return saved;
  var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  return dark && themeExists(THEME_DEFAULT_DARK) ? THEME_DEFAULT_DARK : THEME_DEFAULT_LIGHT;
}

function applyTheme(id, persist) {
  if (!themeExists(id)) id = THEME_DEFAULT_LIGHT;
  document.documentElement.setAttribute('data-theme', id);
  if (persist) { try { localStorage.setItem(THEME_KEY, id); } catch (e) {} }
  var radios = document.querySelectorAll('#themeList input');
  for (var i = 0; i < radios.length; i++) radios[i].checked = radios[i].value === id;
}

applyTheme(initialTheme(), false);

// Called once the body exists: builds the Appearance options from the registry.
function renderThemePicker() {
  var host = document.getElementById('themeList');
  if (!host) return;
  var cur = document.documentElement.getAttribute('data-theme');
  host.innerHTML = THEMES.map(function (th) {
    // Translated label when i18n.js has one for this theme; otherwise the registry label.
    var label = typeof tv === 'function' ? tv('theme', th.id) : th.id;
    if (label === th.id) label = th.label;
    return '<label class="menu-opt"><input type="radio" name="theme" value="' + th.id + '"' +
      (th.id === cur ? ' checked' : '') + ' onchange="applyTheme(this.value,true)">' + label + '</label>';
  }).join('');
}
