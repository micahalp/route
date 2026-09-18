import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const manifest = JSON.parse(
  readFileSync(new URL('../audit/SNAPSHOT.json', import.meta.url), 'utf8'),
);

function verify(file, bytes, label) {
  const hash = createHash('sha256').update(bytes).digest('hex');
  if (hash !== file.sha256 || bytes.length !== file.bytes) {
    throw new Error(`${label} snapshot mismatch: ${file.path}`);
  }
}

// Preserve the original audit manifest. A remediation records an explicit overlay
// and proves the original manifest against the exact audited Git revision.
const overlayUrl = new URL('../audit/REMEDIATION-SNAPSHOT.json', import.meta.url);
const overlay = existsSync(overlayUrl) ? JSON.parse(readFileSync(overlayUrl, 'utf8')) : null;
const replacements = new Map((overlay?.files ?? []).map(file => [file.path, file]));
if (overlay) {
  if (overlay.baseCommit !== 'd9958f70d024955bfb1446ea4f62c403e4c1dabf') {
    throw new Error('Unexpected remediation base');
  }
  for (const file of manifest.files) {
    verify(file, execFileSync('git', ['show', `${overlay.baseCommit}:${file.path}`], { cwd: root }), 'Audited');
  }
}
for (const originalFile of manifest.files) {
  const file = replacements.get(originalFile.path) ?? originalFile;
  verify(
    file,
    readFileSync(new URL('../' + file.path, import.meta.url)),
    'Current',
  );
}
for (const file of replacements.values()) {
  verify(file, readFileSync(new URL('../' + file.path, import.meta.url)), 'Remediation');
}

const baseline = manifest.formattingBaseline;
const originalBytes = readFileSync(
  new URL('../audit/ORIGINAL_SNAPSHOT.json', import.meta.url),
);
const archivedManifest = execFileSync(
  'git',
  ['show', `${baseline.commit}:audit/SNAPSHOT.json`],
  { cwd: root },
);
if (!originalBytes.equals(archivedManifest)) {
  throw new Error('Original manifest differs from the preserved Git baseline');
}
const original = JSON.parse(originalBytes);
for (const file of original.files) {
  const bytes = execFileSync(
    'git',
    ['show', `${baseline.commit}:${file.path}`],
    { cwd: root },
  );
  verify(file, bytes, 'Original');
}

console.log(
  `Verified ${manifest.files.length} current files and ${original.files.length} original baseline files.`,
);
