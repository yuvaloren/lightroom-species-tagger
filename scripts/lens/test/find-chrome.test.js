#!/usr/bin/env node
/*----------------------------------------------------------------------------
scripts/lens/test/find-chrome.test.js
Unit tests for the Chrome version detection. The load-bearing part is picking the
right version FOLDER on Windows (so we never shell out to `chrome --version`, which
pops a phantom browser window there). Pure, so no Chrome needed.
----------------------------------------------------------------------------*/
const { pickChromeVersionDir, chromeVersion } = require('../find-chrome');

let failures = 0;
const check = (name, cond, detail) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !detail ? '' : ' — ' + detail));
  if (!cond) failures++;
};

console.log('pickChromeVersionDir: newest "a.b.c.d" folder, ignoring everything else');
check('picks the newest of several', pickChromeVersionDir(['140.0.7259.5', '139.0.7000.0', '140.0.7300.1']) === '140.0.7300.1');
check('ignores non-version entries', pickChromeVersionDir(['chrome.exe', 'SetupMetrics', '141.0.1.2', 'Dictionaries']) === '141.0.1.2');
check('numeric compare, not lexical (…9 < …10)', pickChromeVersionDir(['1.0.0.9', '1.0.0.10']) === '1.0.0.10');
check('null when nothing matches', pickChromeVersionDir(['chrome.exe', 'Dictionaries']) === null);
check('null on empty / undefined', pickChromeVersionDir([]) === null && pickChromeVersionDir(undefined) === null);

console.log('chromeVersion: always returns a {full,major} shape, never throws');
{
  const v = chromeVersion('/no/such/chrome/here');
  check('has string full + major', !!(v && typeof v.full === 'string' && typeof v.major === 'string'), JSON.stringify(v));
}

console.log(failures === 0 ? '\nPASS — chrome version parsing' : '\nFAIL — ' + failures + ' assertion(s) failed');
process.exit(failures === 0 ? 0 : 1);
