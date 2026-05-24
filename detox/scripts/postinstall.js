const { platform, env } = process;
const fs = require('fs');
const path = require('path');

const { patchGradleByRNVersion } = require('./updateGradle');

const isDarwin = platform === 'darwin';
const shouldInstallDetox = !env.DETOX_DISABLE_POSTINSTALL;

// yarn 3.x git fetcher strips executable bit from shell scripts when
// extracting the cloned monorepo into node_modules. Restore +x on all
// .sh files we ship so postinstall can spawn them.
function restoreShellScriptPermissions() {
  const scriptsDir = __dirname;
  for (const entry of fs.readdirSync(scriptsDir)) {
    if (entry.endsWith('.sh')) {
      try {
        fs.chmodSync(path.join(scriptsDir, entry), 0o755);
      } catch (e) {
        // best-effort
      }
    }
  }
}

if (isDarwin && shouldInstallDetox) {
  restoreShellScriptPermissions();

  const execFileSync = require('child_process').execFileSync;

  execFileSync(`${__dirname}/build_local_framework.ios.sh`, { stdio: 'inherit' });
  try {
    execFileSync(`${__dirname}/build_local_xcuitest.ios.sh`, { stdio: 'inherit' });
  } catch (e) {
    console.warn('[Detox] XCUITest runner build failed, but RN bridge tests will still work:', e.message);
  }
}

patchGradleByRNVersion();
