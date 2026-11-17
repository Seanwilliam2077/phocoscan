import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const appid=process.argv[2];
if(!/^wx[0-9a-f]{16}$/i.test(appid||'')) {
  console.error('Usage: node scripts/Set-WeChatAppId.mjs wx0123456789abcdef\nUse your actual mini-program/test AppID. Do not use AppSecret.');
  process.exit(1);
}
const file=path.join(root,'project.config.json');
const cfg=JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
cfg.appid=appid;
fs.writeFileSync(file,JSON.stringify(cfg,null,2)+'\n');
console.log('AppID updated. Log in with the WeChat account authorized for this AppID, then run scripts/WeChat.ps1 -Action Preview.');
