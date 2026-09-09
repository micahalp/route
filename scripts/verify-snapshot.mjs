import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
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

for (const file of manifest.files) {
  verify(
    file,
    readFileSync(new URL('../' + file.path, import.meta.url)),
    'Current',
  );
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
