import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
const args=process.argv.slice(2),out=args[args.indexOf('--output')+1];
if(!args.includes('--output')||!out)throw Error('Required: --output AUDIT_DIRECTORY');
const read=n=>JSON.parse(fs.readFileSync(path.join(out,n),'utf8').replace(/^\uFEFF/,''));
const coverage=read('coverage.json'),files=read('files.json'),contracts=new Map(),dynamic=[],drift=[];
const sensitive=/(?:password|passwd|secret|token|credential|authorization|^AUTH$|api[_-]?key|private[_-]?key|_KEY$|connection[_-]?string|^LAPLACE_(?:APP_)?DB$|CONNINFO)/i;
const safe=(s,name)=>sensitive.test(name)||/password\s*=|-----BEGIN .*PRIVATE KEY|Bearer\s+\S+|(?:gh[pousr]_|github_pat_|sk_live_|sk-proj-)[A-Za-z0-9_-]{12,}|(?:getenv|GetEnvironmentVariable|SetEnvironmentVariable|setenv)\s*\(\s*["'][^"']*(?:PASSWORD|SECRET|TOKEN|API_KEY)/i.test(s)?'[credential-bearing expression suppressed]':s.replace(/https?:\/\/[^\s/@:]+:[^\s/@]+@/g,'https://[redacted]@').replace(/((?:password|passwd|secret|token|api[_-]?key)\w*["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)/ig,'$1[redacted]').slice(0,1500);
export function classify(file){
 if(/(?:^|\/)[^/]*(?:[._-](?:Tests?|Specs?))(?:\/|\.)|(?:^|\/)(?:tests?|testdata|fixtures?|__tests__)(?:\/|\.)|(?:^|\/)(?:test[-_]|[^/]+[._-](?:test|spec)\.)/i.test(file))return 'test';
 if(/(?:^|\/)(?:vendor|external|third.party|node_modules|_deps)(?:\/)/i.test(file))return 'third-party';
 if(/\.(?:md|rst|adoc)$/i.test(file)||/(?:^|\/)docs?\//.test(file))return 'documentation';
 if(/(?:package-lock\.json|yarn\.lock|\.min\.[jc]s|generated)/i.test(file))return 'generated';
 return 'implementation';
}
const patterns=[
 ['API read',/\b(?:getenv|secure_getenv|GetEnvironmentVariable(?:W|A)?|os\.getenv|os\.environ\.get|(?:std::)?env::var(?:_os)?)\s*\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']/g],
 ['API write',/\b(?:SetEnvironmentVariable|setenv|putenv)\s*\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']/g],
 ['environment accessor',/\b(?:process\.env\.([A-Za-z_][A-Za-z0-9_]*)|(?:process\.env|os\.environ|environ)\s*\[\s*["']([A-Za-z_][A-Za-z0-9_]*)["'])/g],
 ['CMake environment read',/\$ENV\{([A-Za-z_][A-Za-z0-9_]*)\}/g],
 ['PowerShell environment reference',/\$env:([A-Za-z_][A-Za-z0-9_]*)/gi],
 ['default helper',/\b(?:Set-Default|SetThreadVar)\s*\(?\s*["']?([A-Za-z_][A-Za-z0-9_]*)["']?/g],
 ['Laplace flag reader',/\bEnvFlag\.IsSet\s*\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']/g],
 ['Laplace configuration helper',/\b(?:ChessRuntimeConfiguration\.Read|LaplaceInstall\.TryReadConfig|env_or|parse_positive_env|lp_tier0_sibling)\s*\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']/g]
];
let scanned=0;
function scan(bytes,source,file){
 const digest=crypto.createHash('sha256').update(bytes).digest('hex');
 if(digest!==file.sha256){drift.push({source:source.id,file:file.file,reason:'bytes changed after original capture; excluded from this source-based projection'});return;}
 scanned++;const content=bytes.toString('utf8'),lines=content.split(/\r?\n/),seen=new Set(),stringConstants=new Map();
 for(const m of content.matchAll(/\bconst\s+string\s+(\w+)\s*=\s*"([A-Za-z_][A-Za-z0-9_]*)"/g))stringConstants.set(m[1],stringConstants.has(m[1])?null:m[2]);
 const ref=(name,line,kind,statement)=>{
  if(!name||/^(?:env|name|value)$/i.test(name))return;
  const key=line+'\0'+name+'\0'+kind;if(seen.has(key))return;seen.add(key);
  const before=lines.slice(Math.max(0,line-4),line-1).filter(s=>/^\s*(?:#|\/\/|\/\*|\*|rem\b)/i.test(s));
  const own=lines[line-1]||'',trailing=own.match(/\s+(?:#|\/\/)\s+(.+)$/)?.[1];
  const definition=/write|assignment|declaration|default helper/.test(kind)||kind==='PowerShell environment reference'&&new RegExp('\\$env:'+name+'\\s*=' ,'i').test(own);
  const entry={source:source.id,repository:source.repository,revision:source.revision,scope:source.scope,file:file.file,line,domain:classify(file.file),kind,role:definition?'definition':'consumer',expression:safe(statement,name),source_comment:safe([...(trailing?[trailing]:[]),...before].join('\n'),name),content_sha256:digest,url:source.scope==='github-default'?source.url+'/blob/'+source.revision+'/'+file.file.split('/').map(encodeURIComponent).join('/')+'#L'+line:null};
  if(!contracts.has(name))contracts.set(name,{symbol:name,credential:sensitive.test(name),meaning_status:'source expressions and author comments; effective value requires entry-point resolution',evidence:[]});
  contracts.get(name).evidence.push(entry);
 };
 const offsets=[];let pos=0;for(const line of lines){offsets.push(pos);pos+=line.length+(content[pos+line.length]==='\r'?2:1);}
 const lineAt=index=>{let lo=0,hi=offsets.length;while(lo+1<hi){const mid=(lo+hi)>>1;if(offsets[mid]<=index)lo=mid;else hi=mid;}return lo+1;};
 for(const [kind,re]of patterns)for(const match of content.matchAll(re)){
  const line=lineAt(match.index),own=lines[line-1];
  if(/^\s*(?:\/\/|#(?!\s*(?:define|if))|rem\b|\*)/i.test(own))continue;
  if(kind==='PowerShell environment reference'&&!/\.(?:ps1|psm1|psd1)$/i.test(file.file))continue;
  if(kind==='default helper'&&!/\.(?:ps1|psm1|cs)$/i.test(file.file))continue;
  ref(match[1]||match[2],line,kind,lines.slice(line-1,lineAt(match.index+match[0].length)).join('\n'));
 }
 let envIndent=null;
 for(let i=0;i<lines.length;i++){
  const line=lines[i];if(/^\s*(?:#|\/\/|rem\b)/i.test(line))continue;
  for(const m of line.matchAll(/\b(?:GetEnvironmentVariable|SetEnvironmentVariable)\s*\(\s*(\w+)\s*[,)]/g))if(stringConstants.get(m[1]))ref(stringConstants.get(m[1]),i+1,'environment API using a file-local string constant',line);
  if(/LichessServiceHost\.cs$/.test(file.file))for(const m of line.matchAll(/\bNumber\s*\(\s*"([A-Za-z_][A-Za-z0-9_]*)"/g))ref(m[1],i+1,'Lichess numeric environment helper',line);
  if(/\.ya?ml$/i.test(file.file)){
   const indent=line.match(/^\s*/)[0].length;
   if(envIndent!==null&&line.trim()&&indent<=envIndent)envIndent=null;
   if(/^\s*env:\s*(?:#.*)?$/.test(line))envIndent=indent;
   else if(envIndent!==null){const m=line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$/);if(m)ref(m[1],i+1,'workflow environment declaration',line);}
   for(const m of line.matchAll(/\b(vars|secrets)\.([A-Za-z_][A-Za-z0-9_]*)/g))ref(m[2],i+1,'GitHub '+m[1]+' reference',m[1]==='secrets'?'[secret reference; value not collected]':line);
  }
  if(/\.service$/i.test(file.file)&&/^\s*Environment=/.test(line))for(const m of line.matchAll(/(?:Environment=|["'\s])([A-Za-z_][A-Za-z0-9_]*)=/g))ref(m[1],i+1,'service environment declaration',line);
  if(/\.(?:cmd|bat)$/i.test(file.file)){
   for(const m of line.matchAll(/\bset\s+"?([A-Za-z_][A-Za-z0-9_]*)=/gi))ref(m[1],i+1,'CMD process assignment',line);
   for(const m of line.matchAll(/%([A-Za-z_][A-Za-z0-9_]*)%/g))ref(m[1],i+1,'CMD process expansion',line);
  }
  if(/\.(?:sh|bash|env)$|(?:^|\/)laplace\.env(?:\.|$)|(?:^|\.)env(?:\.|$)/i.test(file.file)){
   if(/\bexport\s/.test(line))for(const m of line.matchAll(/(?:\bexport\s+|\s+)([A-Za-z_][A-Za-z0-9_]*)=/g))ref(m[1],i+1,'export assignment',line);
   if(/(?:^|\.)env(?:\.|$)/i.test(file.file))for(const m of line.matchAll(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=/g))ref(m[1],i+1,'environment-file declaration',line);
   for(const m of line.matchAll(/\$\{?((?:LAPLACE_|PG)[A-Za-z0-9_]+)(?=[:}\s/"';]|$)/g))ref(m[1],i+1,'shell parameter reference; export scope unresolved',line);
  }
  if(/(?:CMakeLists\.txt|\.cmake)$/i.test(file.file))for(const m of line.matchAll(/\blaplace_path\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)/g))ref(m[1],i+1,'Laplace CMake path declaration',line);
  if(/\b(?:getenv|GetEnvironmentVariable|SetEnvironmentVariable)\s*\(\s*(?!["'\s])/.test(line)&&!/\b(?:getenv|GetEnvironmentVariable|SetEnvironmentVariable)\s*\(\s*["']/.test(line))dynamic.push({source:source.id,file:file.file,line:i+1,expression:'Computed name or helper parameter; inspect source at this location.'});
 }
}
for(const source of coverage.sources){
 if(source.empty)continue;const selected=files.filter(f=>f.source===source.id);
 if(source.scope==='github-default'){
  for(let i=0;i<selected.length;){let bytes=0;const batch=[];do{const f=selected[i++];batch.push(f);bytes+=f.bytes;}while(i<selected.length&&bytes<24*1024*1024);
   const buffer=execFileSync('git',['-C',source.path,'cat-file','--batch'],{input:batch.map(f=>f.git_blob).join('\n')+'\n',maxBuffer:Math.max(64*1024*1024,bytes+batch.length*100)});let offset=0;
   for(const file of batch){const end=buffer.indexOf(10,offset),header=buffer.subarray(offset,end).toString().split(' '),size=Number(header[2]);if(header[1]!=='blob'||!Number.isFinite(size))throw Error('Missing captured blob '+source.id+'/'+file.file);scan(buffer.subarray(end+1,end+1+size),source,file);offset=end+size+2;}
  }
 }else for(const file of selected){try{scan(fs.readFileSync(path.join(source.path,file.file)),source,file);}catch(e){drift.push({source:source.id,file:file.file,reason:'captured local file no longer readable'});}}
}
const entries=[...contracts.values()].sort((a,b)=>a.symbol.localeCompare(b.symbol));
const db=new DatabaseSync(path.join(out,'configuration.sqlite'));db.exec('DROP TABLE IF EXISTS environment_contracts; DROP TABLE IF EXISTS environment_evidence; CREATE TABLE environment_contracts(symbol TEXT PRIMARY KEY,payload TEXT); CREATE TABLE environment_evidence(id INTEGER PRIMARY KEY,source TEXT,repository TEXT,scope TEXT,category TEXT,symbol TEXT,domain TEXT,role TEXT,file TEXT,payload TEXT); BEGIN;');
const insert=db.prepare('INSERT INTO environment_contracts VALUES(?,?)'),insertEvidence=db.prepare('INSERT INTO environment_evidence(source,repository,scope,category,symbol,domain,role,file,payload) VALUES(?,?,?,?,?,?,?,?,?)');
for(const entry of entries){insert.run(entry.symbol,JSON.stringify(entry));for(const evidence of entry.evidence){const row={...evidence,symbol:entry.symbol,category:'environment',snippet:evidence.expression};insertEvidence.run(row.source,row.repository,row.scope,row.category,row.symbol,row.domain,row.role,row.file,JSON.stringify(row));}}
db.exec('COMMIT;');db.close();
fs.writeFileSync(path.join(out,'environment-contracts.json'),JSON.stringify({files_checked:scanned,terms:entries.length,scope:'Literal environment APIs, explicit exports, environment-file declarations and CMD/PowerShell process variables. CMD scratch variables are process state, not automatically operator settings. Shell-local expansions are not claimed to be exported.',drift,dynamic_name_sites:dynamic,entries},null,2)+'\n');
fs.writeFileSync(path.join(out,'environment-glossary.json'),JSON.stringify(entries,null,2)+'\n');
coverage.environment_names_with_direct_evidence=entries.length;
coverage.environment_contracts={files_checked:scanned,terms:entries.length,evidence:entries.reduce((n,e)=>n+e.evidence.length,0),dynamic_name_sites:dynamic.length,local_drift:drift,method:'Re-read captured source bytes; identify literal APIs, explicit exports, workflow/service declarations and process variables before credential suppression. SQL SET and compile guards are excluded.'};
fs.writeFileSync(path.join(out,'coverage.json'),JSON.stringify(coverage,null,2)+'\n');
fs.writeFileSync(path.join(out,'data.js'),'window.CONFIG_AUDIT='+JSON.stringify({coverage}).replaceAll('<','\\u003c')+';\n');
const csv=s=>'"'+String(s??'').replace(/^[=+@-]/,"'$&").replaceAll('"','""')+'"';
const csvPath=path.join(out,'environment-contracts.csv'),fd=fs.openSync(csvPath,'w');fs.writeSync(fd,'symbol,repository,scope,kind,role,domain,file,line,expression,source_comment,url\r\n');for(const e of entries)for(const r of e.evidence)fs.writeSync(fd,[e.symbol,r.repository,r.scope,r.kind,r.role,r.domain,r.file,r.line,r.expression,r.source_comment,r.url].map(csv).join(',')+'\r\n');fs.closeSync(fd);
const lookup=new DatabaseSync(path.join(out,'configuration.sqlite'),{readOnly:true});
const categories=lookup.prepare("SELECT source,category,count(*) occurrences,count(distinct symbol) symbols FROM occurrences WHERE scope='github-default' GROUP BY source,category ORDER BY category").all();
const configFiles=lookup.prepare("SELECT source,file,count(*) occurrences FROM occurrences WHERE scope='github-default' AND domain='implementation' AND category IN ('configuration','database-setting','environment','environment-candidate') GROUP BY source,file ORDER BY file").all();
const repositories=coverage.sources.filter(s=>s.scope==='github-default').map(source=>({repository:source.repository,revision:source.revision,empty:!!source.empty,environment_names:entries.filter(e=>e.evidence.some(r=>r.source===source.id)).map(e=>e.symbol),categories:categories.filter(c=>c.source===source.id),configuration_files:configFiles.filter(f=>f.source===source.id).map(f=>({...f,url:source.url+'/blob/'+source.revision+'/'+f.file.split('/').map(encodeURIComponent).join('/')}))}));
lookup.close();fs.writeFileSync(path.join(out,'repository-index.json'),JSON.stringify({repositories},null,2)+'\n');
const reviewPath=new URL('./reports/configuration-contract-review.json',import.meta.url);
if(fs.existsSync(reviewPath)){
 const review=JSON.parse(fs.readFileSync(reviewPath,'utf8'));
 const applies=review.contracts.every(c=>c.evidence.every(e=>coverage.sources.some(s=>s.repository===e.repository&&s.scope==='github-default'&&s.revision===e.revision)));
 fs.writeFileSync(path.join(out,'configuration-review.json'),JSON.stringify(applies?review:{status:'Review does not apply to these source revisions',contracts:[],findings:[]},null,2)+'\n');
}
console.log(JSON.stringify({files_checked:scanned,terms:entries.length,evidence:entries.reduce((n,e)=>n+e.evidence.length,0),drift:drift.length,dynamic_name_sites:dynamic.length}));
