import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const manifest=JSON.parse(readFileSync(new URL('../audit/SNAPSHOT.json',import.meta.url),'utf8'));
for(const file of manifest.files){const bytes=readFileSync(new URL('../'+file.path,import.meta.url));if(createHash('sha256').update(bytes).digest('hex')!==file.sha256)throw Error('Snapshot mismatch: '+file.path);}
console.log('Verified '+manifest.files.length+' exact source/evidence files.');
