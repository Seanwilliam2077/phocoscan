// Original vector icons. Optional build-time sharp path; no player dependency.
const fs=require('node:fs'),path=require('node:path');
const sharp=require(process.argv[2]||'sharp');
const out=path.resolve(__dirname,'../miniprogram/assets/tabs');fs.mkdirSync(out,{recursive:true});
const icons={
  town:'<path d="M10 30 32 12l22 18M16 26v28h32V26M27 54V37h10v17"/>',
  explore:'<circle cx="32" cy="32" r="23"/><path d="m42 22-6 14-14 6 6-14Z"/><circle cx="32" cy="32" r="2"/>',
  journal:'<rect x="10" y="15" width="44" height="36" rx="7"/><path d="m12 20 20 17 20-17M12 48l14-14m26 14L38 34"/>',
  settings:'<path d="M12 18h40M12 32h40M12 46h40"/><circle cx="24" cy="18" r="5" fill="white"/><circle cx="42" cy="32" r="5" fill="white"/><circle cx="25" cy="46" r="5" fill="white"/>'
};
(async()=>{for(const [name,shape]of Object.entries(icons)){for(const active of [false,true]){const svg='<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><g fill="none" stroke="'+(active?'#188b79':'#80958e')+'" stroke-width="3.8" stroke-linejoin="round" stroke-linecap="round">'+shape+'</g></svg>';await sharp(Buffer.from(svg)).png().toFile(path.join(out,name+(active?'-active':'')+'.png'));}}})();
