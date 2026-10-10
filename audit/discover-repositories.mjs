import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
const args=process.argv.slice(2),output=path.resolve(args[args.indexOf('--output')+1]||'');
if(!args.includes('--roots')||!args.includes('--output'))throw Error('Required: --roots ROOT1;ROOT2 --output AUDIT_DIRECTORY');
const roots=args[args.indexOf('--roots')+1].split(';'),stack=[...roots],repositories=[],omissions=[];
while(stack.length){
 const dir=path.resolve(stack.pop());if(dir===output){omissions.push({path:dir,reason:'audit output/cache'});continue;}
 if(fs.existsSync(path.join(dir,'.git'))){
  const record={path:dir};
  for(const [key,command]of [['revision',['rev-parse','HEAD']],['origin',['config','--get','remote.origin.url']]]){
   try{record[key]=execFileSync('git',['-C',dir,...command],{encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim().replace(/https?:\/\/[^/@:]+:[^/@]+@/g,'https://[redacted]@');}catch{record[key]=null;}
  }
  record.family=/laplace|hartonomous|hart-mcp/i.test(dir+' '+(record.origin||''))&&!/[\\/](?:external|_deps)[\\/]/i.test(dir);
  repositories.push(record);continue;
 }
 let entries;try{entries=fs.readdirSync(dir,{withFileTypes:true});}catch{omissions.push({path:dir,reason:'directory not readable'});continue;}
 for(const entry of entries){
  if(!entry.isDirectory()||entry.isSymbolicLink())continue;
  const next=path.join(dir,entry.name);
  if(/^(?:node_modules|\.git|\.venv|\$RECYCLE\.BIN|System Volume Information)$/.test(entry.name)){omissions.push({path:next,reason:'dependency/cache or operating-system directory'});continue;}
  stack.push(next);
 }
}
fs.writeFileSync(path.join(output,'repository-discovery.json'),JSON.stringify({roots,depth_limit:null,repositories,omissions},null,2)+'\n');
console.log(JSON.stringify({repositories:repositories.length,family:repositories.filter(r=>r.family).length,unreadable:omissions.filter(x=>x.reason==='directory not readable').length}));
