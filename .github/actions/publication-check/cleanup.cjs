const fs = require('node:fs');
const path = require('node:path');
try {
  const stage = process.env.STATE_publication_stage;
  if (stage && fs.existsSync(stage)) {
    const root = fs.realpathSync(process.env.RUNNER_TEMP);
    if (path.dirname(path.resolve(stage)) !== root || !/^publication-[A-Za-z0-9]+$/.test(path.basename(stage))) throw new Error('invalid cleanup target');
    fs.rmSync(stage, {recursive: true, force: true});
  }
} catch {
  process.stderr.write('Security cleanup could not complete. Run repository checks locally first.\n');
  process.exitCode = 1;
}
