/*----------------------------------------------------------------------------
scripts/lens/find-chrome.js
Locate the installed Google Chrome across macOS / Windows / Linux, and read its
version, so both the helper (lens-search.js) and its tests use the SAME browser.
Override the path with LENS_CHROME=/path/to/chrome (or chrome.exe).

Version detection uses `chrome --version` — a clean print-and-exit — on every
platform EXCEPT Windows, where `chrome.exe --version` pops a briefly-visible
browser window and doesn't even print to stdout. So on Windows only, we read the
version from the install layout instead (the Application dir next to chrome.exe
holds a <major.minor.build.patch> folder): no subprocess, no phantom window.
----------------------------------------------------------------------------*/
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

function findChrome() {
  if (process.env.LENS_CHROME) return process.env.LENS_CHROME;
  const IS_WIN = process.platform === 'win32';
  const pf = process.env['ProgramFiles'] || 'C:\\Program Files';
  const pfx86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
  const local = process.env['LOCALAPPDATA'] || path.join(os.homedir(), 'AppData', 'Local');
  const candidates = IS_WIN ? [
    path.join(pf, 'Google\\Chrome\\Application\\chrome.exe'),
    path.join(pfx86, 'Google\\Chrome\\Application\\chrome.exe'),
    path.join(local, 'Google\\Chrome\\Application\\chrome.exe'),
    path.join(pf, 'Google\\Chrome Beta\\Application\\chrome.exe'),
    path.join(pf, 'Chromium\\Application\\chrome.exe'),
  ] : process.platform === 'darwin' ? [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
  ] : [
    '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/opt/google/chrome/chrome',
    '/usr/bin/chromium', '/usr/bin/chromium-browser', '/snap/bin/chromium',
  ];
  for (const c of candidates) { try { if (fs.existsSync(c)) return c; } catch (_) {} }
  return IS_WIN ? 'chrome.exe' : 'google-chrome'; // last resort: hope it's on PATH
}

// From a list of directory-entry names, return the highest "a.b.c.d" version folder
// (Windows Chrome keeps one per installed version next to chrome.exe). Pure — testable.
function pickChromeVersionDir(entries) {
  const vers = (entries || []).filter(e => /^\d+\.\d+\.\d+\.\d+$/.test(e))
    .sort((a, b) => {
      const pa = a.split('.').map(Number), pb = b.split('.').map(Number);
      for (let i = 0; i < 4; i++) { if (pa[i] !== pb[i]) return pa[i] - pb[i]; }
      return 0;
    });
  return vers[vers.length - 1] || null;
}

// Real installed Chrome version (used to match UA + Client Hints so Google serves the
// normal Lens page). `chrome --version` everywhere except Windows, which reads the version
// folder instead (see the header note). Falls back to a recent default.
function chromeVersion(chromePath) {
  const chrome = chromePath || findChrome();
  const FALLBACK = { full: '149.0.0.0', major: '149' };
  if (process.platform === 'win32') {
    try {
      const best = pickChromeVersionDir(fs.readdirSync(path.dirname(chrome)));
      if (best) return { full: best, major: best.split('.')[0] };
    } catch (_) {}
    return FALLBACK;
  }
  try {
    const v = execFileSync(chrome, ['--version'], { timeout: 10000 }).toString();
    const m = v.match(/(\d+)\.\d+\.\d+\.\d+/);
    if (m) return { full: m[0], major: m[1] };
  } catch (_) {}
  return FALLBACK;
}

module.exports = { findChrome, chromeVersion, pickChromeVersionDir };
