// Preload for the real lavish-axi CLI: intercepts the `open` package's browser
// launch (powershell.exe Start on WSL, xdg-open elsewhere) and records each
// would-be browser tab to $BROWSER_OPEN_LOG instead of opening Chrome.
const cp = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const realSpawn = cp.spawn;
cp.spawn = function (command, args, options) {
  const base = path.basename(String(command)).toLowerCase();
  if (/powershell|xdg-open|wslview|cmd\.exe/.test(base)) {
    let url = null;
    const a = Array.isArray(args) ? args : [];
    const i = a.indexOf('-EncodedCommand');
    if (i >= 0 && a[i + 1]) url = Buffer.from(a[i + 1], 'base64').toString('utf16le');
    else url = a[a.length - 1];
    fs.appendFileSync(process.env.BROWSER_OPEN_LOG,
      JSON.stringify({ at: new Date().toISOString(), launcher: base, target: url }) + '\n');
    return realSpawn.call(this, 'true', [], { stdio: 'ignore', detached: true });
  }
  return realSpawn.apply(this, arguments);
};
require('node:module').syncBuiltinESMExports();
