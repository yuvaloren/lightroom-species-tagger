/*----------------------------------------------------------------------------
scripts/lens/find-chrome.js
Locate the installed Google Chrome across macOS / Windows / Linux, so both the
helper (lens-search.js) and its tests launch the SAME browser. Override with
LENS_CHROME=/path/to/chrome (or chrome.exe). Returns the first path that exists,
falling back to a bare name on PATH. Pure lookup — no side effects.
----------------------------------------------------------------------------*/
const fs = require('fs');
const path = require('path');
const os = require('os');

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

module.exports = { findChrome };
