import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const mini=path.join(root,'miniprogram');
const work=path.join(root,'work','weapp-build');
fs.mkdirSync(work,{recursive:true});
const json=f=>JSON.parse(fs.readFileSync(f,'utf8').replace(/^\uFEFF/,''));
function fail(message){console.error(message);process.exit(1);}
const config=json(path.join(root,'project.config.json')),app=json(path.join(mini,'app.json'));
if(config.miniprogramRoot!=='miniprogram/'||config.compileType!=='miniprogram')fail('Unexpected packaging root: private server files must stay outside the mini-program.');
const files=[];
function walk(dir){for(const item of fs.readdirSync(dir,{withFileTypes:true})){const file=path.join(dir,item.name);if(item.isDirectory())walk(file);else files.push(file);}}
walk(mini);
for(const page of app.pages)for(const suffix of ['.js','.json','.wxml','.wxss'])if(!fs.existsSync(path.join(mini,page+suffix)))fail('Missing page file: '+page+suffix);
if(!app.tabBar)for(const page of app.pages){if(/\bwx\.switchTab\s*\(/.test(fs.readFileSync(path.join(mini,page+'.js'),'utf8')))fail('A page uses switchTab but this minimal app has no tabBar: '+page);}
for(const file of files){
  if(file.endsWith('.json'))json(file);
  if(file.endsWith('.js')){
    const result=spawnSync(process.execPath,['--check',file],{encoding:'utf8'});if(result.status!==0)fail(result.stderr);
    for(const match of fs.readFileSync(file,'utf8').matchAll(/\brequire\(\s*['"]([^'"]+)['"]\s*\)/g)){
      const specifier=match[1];
      if(!specifier.startsWith('.'))fail('Unexpected non-relative native dependency: '+specifier);
      const resolved=path.resolve(path.dirname(file),specifier+(specifier.endsWith('.js')?'':'.js'));
      if(!resolved.startsWith(mini+path.sep)||!fs.existsSync(resolved))fail('WeChat cannot load this JS module: '+specifier+' in '+file);
    }
  }
  if(file.endsWith('.wxml')&&/<web-view\b/i.test(fs.readFileSync(file,'utf8')))fail('Native-only MVP cannot package a web-view: '+file);
  if(/\.(?:html|mp4|mov|ply|splat|sqlite|db)$/i.test(file))fail('Unexpected raw media / web / database file in player bundle: '+file);
}
const devtools=process.env.WECHAT_DEVTOOLS_PATH||'D:\\WeChatDevTools';
const compilers=path.join(devtools,'resources','app.asar.unpacked','node_modules','wcc-exec');
let officialCompiler=false;
if(fs.existsSync(path.join(compilers,'wcc.exe'))&&fs.existsSync(path.join(compilers,'wcsc.exe'))){
  for(const [binary,ext,out]of [['wcc.exe','.wxml','templates.js'],['wcsc.exe','.wxss','styles.js']]){
    const inputs=files.filter(f=>f.endsWith(ext)).map(f=>path.relative(mini,f).replaceAll('\\','/'));
    const result=spawnSync(path.join(compilers,binary),['-o',path.join(work,out),...inputs],{cwd:mini,encoding:'utf8',maxBuffer:16*1024*1024});
    fs.writeFileSync(path.join(work,binary+'.log'),(result.stdout||'')+(result.stderr||''));
    if(result.status!==0)fail(binary+' failed ('+result.status+'): '+result.stderr+' '+result.stdout);
    if(!fs.statSync(path.join(work,out)).size)fail(binary+' produced no output');
  }
  officialCompiler=true;
}else console.warn('Official wcc/wcsc not found; only static checks ran. Install WeChat DevTools or set WECHAT_DEVTOOLS_PATH.');
const report={time:new Date().toISOString(),pages:app.pages.length,files:files.length,bundleSourceBytes:files.reduce((n,f)=>n+fs.statSync(f).size,0),jsSyntax:true,json:true,officialWxmlWxssCompile:officialCompiler,appidConfigured:/^wx[0-9a-f]{16}$/i.test(config.appid||''),devtoolsSimulator:false,iphoneTested:false};
fs.writeFileSync(path.join(work,'report.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));
if(process.argv.includes('--require-compiler')&&!officialCompiler)fail('Official compiler required.');
