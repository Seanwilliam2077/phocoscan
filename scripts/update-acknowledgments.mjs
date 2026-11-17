import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const sources=['docs/THIRD-PARTY-NOTICES.md','docs/licenses/spz-swift-LICENSE.txt','docs/licenses/spz-swift-NOTICE.txt','docs/licenses/swift-argument-parser-LICENSE.txt'];
const contents=sources.map(p=>`${p}\n\n${fs.readFileSync(path.join(root,p),'utf8')}`).join('\n\n--------------------------------------------------\n\n');
const target=path.join(root,'ios/PocketWorld/Resources/Acknowledgments.txt');
fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,contents);
console.log('Native in-app third-party acknowledgments updated.');
