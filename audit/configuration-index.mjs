import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {DatabaseSync} from 'node:sqlite';

const argv=process.argv.slice(2), output=argv[argv.indexOf('--output')+1];
if(!argv.includes('--output') || !output) throw Error('Usage: node audit/configuration-index.mjs --output AUDIT_DIRECTORY');
const out=path.resolve(output), readJson=f=>JSON.parse(fs.readFileSync(f,'utf8').replace(/^\uFEFF/,''));
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const git=(root,args,options={})=>execFileSync('git',['-C',root,...args],{maxBuffer:512*1024*1024,...options});
const acquisitions=readJson(path.join(out,'acquisition.json'));
const catalog=readJson(path.join(out,'catalog.json'));
// Validate acquired tree entries before opening/truncating any existing outputs.
// The API cache may identify the requested commit or the resolved tree object.
const validatedTrees=new Map();
for(const acquired of acquisitions){
  if(acquired.exit_code!==0||acquired.empty)continue;
  let treeFile=path.join(out,'trees',acquired.name+'-'+acquired.revision+'.json');
  if(!fs.existsSync(treeFile))treeFile=path.join(out,'trees',acquired.name+'.json');
  if(!fs.existsSync(treeFile))continue;
  const metadata=readJson(treeFile);
  if(metadata.truncated)throw Error('Truncated tree: '+acquired.name);
  const local=git(acquired.path,['ls-tree','-rz',acquired.revision]).toString('utf8').split('\0').filter(Boolean).map(s=>{const m=s.match(/^(\d+) (\w+) ([a-f\d]+)\t([\s\S]+)$/);if(!m)throw Error('Invalid Git tree entry');return {mode:m[1],type:m[2],oid:m[3],file:m[4]};});
  const expected=new Map(local.map(e=>[e.file,e])),actual=metadata.tree.filter(e=>e.type!=='tree');
  if(actual.length!==local.length||actual.some(e=>{const a=expected.get(e.path);return !a||a.oid!==e.sha||a.mode!==e.mode||a.type!==e.type;}))throw Error('Tree entries differ from pinned commit: '+acquired.name);
  validatedTrees.set(acquired.name,metadata);
}
const previous=argv.includes('--append')?readJson(path.join(out,'coverage.json')):null;
const sources=previous?previous.sources:[], files=previous?readJson(path.join(out,'files.json')):[], skipped=previous?readJson(path.join(out,'skipped.json')):[], failures=previous?previous.failures:[],discovery=previous?readJson(path.join(out,'discovery.json')):[];
const database=new DatabaseSync(path.join(out,'configuration.sqlite'));
database.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;');
if(!previous)database.exec(`
DROP TABLE IF EXISTS occurrences; DROP TABLE IF EXISTS glossary;
CREATE TABLE occurrences(id INTEGER PRIMARY KEY,source TEXT,repository TEXT,scope TEXT,category TEXT,symbol TEXT,domain TEXT,role TEXT,file TEXT,payload TEXT);
CREATE TABLE glossary(category TEXT,symbol TEXT,occurrences INTEGER,payload TEXT);`);
database.exec('BEGIN;');
const insert=database.prepare('INSERT INTO occurrences(source,repository,scope,category,symbol,domain,role,file,payload) VALUES(?,?,?,?,?,?,?,?,?)');
const jsonFile=fs.openSync(path.join(out,'occurrences.jsonl'),previous?'a':'w'),csvFile=fs.openSync(path.join(out,'occurrences.csv'),previous?'a':'w');
const cols=['category','symbol','repository','scope','revision','file','line','role','expression','unit','domain','snippet','url'];
const csv=s=>{let value=String(s??'');if(/^[=+@-]/.test(value))value="'"+value;return '"'+value.replaceAll('"','""')+'"';};
if(!previous)fs.writeSync(csvFile,'\uFEFF'+cols.join(',')+'\r\n');
let jsonBuffer=[],csvBuffer=[];
const flushRows=()=>{if(jsonBuffer.length){fs.writeSync(jsonFile,jsonBuffer.join(''));fs.writeSync(csvFile,csvBuffer.join(''));jsonBuffer=[];csvBuffer=[];}};
const rows={length:previous?previous.occurrences:0,push(row){const json=JSON.stringify(row);insert.run(row.source,row.repository,row.scope,row.category,row.symbol,row.domain,row.role,row.file,json);jsonBuffer.push(json+'\n');csvBuffer.push(cols.map(c=>csv(row[c])).join(',')+'\r\n');this.length++;if(jsonBuffer.length>=500)flushRows();},
  *[Symbol.iterator](){for(const row of database.prepare('SELECT payload FROM occurrences ORDER BY id').iterate())yield JSON.parse(row.payload);}};
function writeArray(file,values){const fd=fs.openSync(file,'w');fs.writeSync(fd,'[\n');let first=true;for(const value of values){fs.writeSync(fd,(first?'':',\n')+JSON.stringify(value));first=false;}fs.writeSync(fd,'\n]\n');fs.closeSync(fd);}
const started=new Date().toISOString(),scannerHash=hash(fs.readFileSync(fileURLToPath(import.meta.url)));
fs.mkdirSync(path.join(out,'scanner-versions'),{recursive:true});fs.copyFileSync(fileURLToPath(import.meta.url),path.join(out,'scanner-versions',scannerHash+'.mjs'));
const numeric=/\b(?:0x[\da-f]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?)(?:[uUlLfF]|[KMGT]i?B|ms|GB|MB|KB)?\b/i;
const parameterName=/(?:batch|chunk|limit|threshold|timeout|retry|retries|backoff|threads?|workers?|parallel|concurren|buffer|cache|memory|pool|connections?|budget|capacity|queue|size|count|length|depth|fanout|hops|window|interval|ttl|latency|rate|precision|tolerance|epsilon|cutoff|minimum|maximum|reserve|headroom|port|host|directory|folder|path|prefix)/i;
const secretName=/(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|connection[_-]?string|^LAPLACE_(?:APP_)?DB$)/i;
const binaryExtensions=/\.(?:png|jpe?g|gif|webp|ico|woff2?|ttf|otf|pdf|zip|gz|xz|zst|7z|tar|dll|exe|lib|pdb|obj|o|a|so(?:\.\d+)*|bin|pack|idx|mp[34]|wav|ogg|flac|parquet|gguf|onnx|pt|pth|safetensors|blend)$/i;
function scrub(line,symbol='') {
  if(secretName.test(symbol) || /(?:Password\s*=|-----BEGIN .*PRIVATE KEY|Bearer\s+\S+|(?:gh[pousr]_|github_pat_|sk_live_|sk-proj-)[A-Za-z0-9_-]{12,})/i.test(line))
    return '[credential-bearing context omitted; inspect the cited source]';
  return line.replace(/https?:\/\/[^\s/@:]+:[^\s/@]+@/g,'https://[redacted]@')
    .replace(/((?:password|passwd|secret|token|api[_-]?key)\w*["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)/ig,'$1[redacted]').slice(0,900);
}
function domain(file) {
  if(/(?:^|\/)[^/]*(?:[._-](?:Tests?|Specs?))(?:\/|\.)|(?:^|\/)(?:tests?|testdata|fixtures?|__tests__)(?:\/|\.)|(?:^|\/)(?:test[-_]|[^/]+[._-](?:test|spec)\.)/i.test(file)) return 'test';
  if(/(?:^|\/)(?:vendor|external|third.party|node_modules)(?:\/)/i.test(file)) return 'third-party';
  if(/\.(?:md|rst|txt|adoc)$/i.test(file) || /(?:^|\/)docs?\//.test(file)) return 'documentation';
  if(/(?:package-lock\.json|yarn\.lock|\.min\.[jc]s|generated)/i.test(file)) return 'generated';
  return 'implementation';
}
function scan(text,source,file,sha) {
  const lines=text.split(/\r?\n/), seen=new Set(), kind=domain(file), safeLines=new Map();
  const add=(line,category,symbol,role='reference',expression='')=>{
    if(!symbol || symbol.length>260) return;
    const k=`${line}\0${category}\0${symbol}`; if(seen.has(k)) return; seen.add(k);
    // Inline JSON can put thousands of settings on one line. Scrub that line once;
    // credential-named symbols still suppress their entire context separately.
    if(!safeLines.has(line))safeLines.set(line,scrub(lines[line-1]||''));
    const safe=secretName.test(symbol)?scrub('',symbol):safeLines.get(line);
    const value=scrub(expression,symbol);
    const credential=secretName.test(symbol);
    const unit=expression.match(/\b(?:GiB|MiB|KiB|GB|MB|KB|milliseconds|seconds|minutes|bytes|kilobytes)\b/i)?.[0]||null;
    rows.push({source:source.id,repository:source.repository,revision:source.revision,scope:source.scope,file,line,
      category,symbol,role,expression:value||null,unit,domain:kind,credential,content_sha256:sha,
      snippet:safe,meaning_status:'unreviewed',
      source_note:lines.slice(Math.max(0,line-4),line-1).filter(s=>/^\s*(?:#|\/\/|\/\*|\*|<!--|rem\b)/i.test(s)).map(s=>scrub(s,symbol)).join('\n')||null,
      url:source.scope==='github-default'?`${source.url}/blob/${source.revision}/${file.split('/').map(encodeURIComponent).join('/')}#L${line}`:null});
  };
  // JSON keys need their full object/array path, including inline/minified objects.
  // A line regex loses later keys and conflates equal leaf names in different sections.
  if(/\.json$/i.test(file)) {
    let valid=true;try{JSON.parse(text);}catch{valid=false;}
    if(valid){let pos=0,line=1;
      const space=()=>{while(/\s/.test(text[pos]||'!')){if(text[pos++]==='\n')line++;}};
      const string=()=>{const start=pos++;while(pos<text.length){const c=text[pos++];if(c==='\\')pos++;else if(c==='"')break;}return text.slice(start,pos);};
      const value=(key,at)=>{space();const start=pos;
        if(text[pos]==='{'){pos++;space();while(text[pos]!=='}'){const keyLine=line,name=JSON.parse(string());space();pos++;value(key?key+'.'+name:name,keyLine);space();if(text[pos]!==',')break;pos++;space();}pos++;}
        else if(text[pos]==='['){pos++;space();let n=0;while(text[pos]!==']'){value(key+'['+(n++)+']',line);space();if(text[pos]!==',')break;pos++;space();}pos++;}
        else {if(text[pos]==='"')string();else while(pos<text.length&&!/[\s,\]}]/.test(text[pos]))pos++;add(at,'configuration',key||'$','definition',text.slice(start,pos));}
      };space();value('',line);
    }
  }
  for(let i=0;i<lines.length;i++) {
    const line=lines[i], n=i+1;
    // Configuration names are indexed in prose and test fixtures as well as executable code.
    for(const m of line.matchAll(/\bLAPLACE_[A-Z][A-Z0-9_]*\b/g)) {
      const definition=new RegExp(`(?:Set-Default\\s+${m[0]}\\b|(?:export\\s+)?${m[0]}\\s*(?:=|:)|<${m[0]}(?:\\s|>))`).test(line);
      add(n,'environment-candidate',m[0],definition?'definition':'reference',definition?line.trim():'');
    }
    const envPatterns=[
      /\$env:([A-Za-z_][A-Za-z0-9_]*)/g, /%([A-Za-z_][A-Za-z0-9_]*)%/g,
      /\$\{([A-Z_][A-Z0-9_]*)(?=[:}\-+?])/g, /\$([A-Z_][A-Z0-9_]*)\b/g,
      /\b(?:process\.env|env)\.([A-Z_][A-Z0-9_]*)/g,
      /\b(?:getenv|secure_getenv|GetEnvironmentVariable|GetEnvironmentVariableW|EnvironmentVariable|std::env::var|env::var)\s*\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']/g,
      /\b(?:environ|process\.env|os\.environ)\s*\[\s*["']([^"']+)["']/g,
      /\b(?:os\.getenv|os\.environ\.get|env::var_os)\s*\(\s*["']([^"']+)["']/g,
      /\b(?:export|Set-Default)\s+([A-Z_][A-Z0-9_]*)\b/g,
      /\bset\s+"?([A-Z_][A-Z0-9_]*)=/gi
    ];
    for(const re of envPatterns) for(const m of line.matchAll(re)) {
      const def=/(?:Set-Default\s|\bexport\s|\bset\s)/i.test(line)||new RegExp(`\\b${m[1]}\\s*=`).test(line);
      add(n,'environment-candidate',m[1],def?'definition':'reference',def?line.trim():'');
    }
    // Calls split across lines, with the literal name on the following line.
    if(/\b(?:getenv|GetEnvironmentVariable|os\.getenv|env::var)\s*\(\s*$/.test(line)) {
      const next=lines[i+1]||'', m=next.match(/^\s*["']([A-Za-z_][A-Za-z0-9_]*)["']/);
      if(m) add(i+2,'environment-candidate',m[1],'reference');
    }
    for(const m of line.matchAll(/([A-Za-z]:[\\/][^"'<>|\r\n]*|\/(?:opt|etc|repos|build|vault|archive|backup|data|home|usr|var|run|mnt|srv|pgtemp|tmp|proc|sys|dev)(?:\/[^\s"'<>;,)}\]]*)?)/g)) {
      let value=m[1].trim(); if(/^[A-Za-z]:/.test(value)) value=value.replace(/\s+(?:#|rem\b|\/\/).*$/,'').replace(/[);]+$/,'');
      add(n,'path',value,'literal',value);
    }
    for(const m of line.matchAll(/\$\{?[A-Z_][A-Z0-9_]*\}?[\\/][^\s"'<>;,)}\]]+/g)) add(n,'path',m[0],'derived',m[0]);
    for(const m of line.matchAll(/(?:^|[\s"'=(])(--[a-z][a-z0-9-]*)(?=[\s="'),]|$)/g)) add(n,'option',m[1],'reference',line.trim());
    let m;
    if((m=line.match(/^\s*#\s*define\s+([A-Za-z_]\w*)\s+(.+)/))) add(n,'constant',m[1],'definition',m[2]);
    // All named numeric assignments, including names without tuning-related words.
    for(const a of line.matchAll(/\b([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*(?:=|:)\s*([^;\r\n]+)/g)) {
      if(numeric.test(a[2]) || parameterName.test(a[1])) add(n,parameterName.test(a[1])?'parameter':'numeric-assignment',a[1],'candidate-definition',a[2].trim());
    }
    if((m=line.match(/\b(?:const|constexpr|readonly)\s+(?:[\w<>:*?]+\s+)*([A-Za-z_]\w*)\s*=\s*(.+)/))) add(n,'constant',m[1],'definition',m[2]);
    if((m=line.match(/\b([A-Za-z_]\w*)\s*\[\s*(\d+|[A-Z_][A-Z0-9_]*)\s*\]\s*(?:=|;)/))) add(n,'array-bound',m[1],'definition',m[2]);
    if((m=line.match(/\b([A-Za-z_]\w*)\s*\{[^}]*\}\s*=\s*(.+)/)) && numeric.test(m[2])) add(n,'parameter',m[1],'candidate-definition',m[2]);
    if((m=line.match(/^\s*(?:option|set)\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s+(.+)/i)) && /(?:CMakeLists\.txt|\.cmake)$/i.test(file)) add(n,'configuration',m[1],'definition',m[2]);
    if((m=line.match(/\bDefineCustom\w+Variable\s*\(\s*"([^"]+)"/))) add(n,'database-setting',m[1],'definition',line.trim());
    if(!secretName.test(lines.slice(Math.max(0,i-1),i+1).join('\n')))
      for(const setting of line.matchAll(/["']([A-Z][A-Z0-9]*_[A-Z0-9_]+)["']/g)) add(n,'identifier-string',setting[1],'candidate',line.trim());
    const configFile=/\.(?:json|ya?ml|toml|ini|conf|config|env|properties|service|timer|props|targets|csproj|psd1)$/i.test(file)||/(?:CMakeLists\.txt|Dockerfile|\.env(?:\.|$))/.test(file);
    if(configFile && (m=line.match(/^\s*["']?([A-Za-z_][\w.:-]*)["']?\s*[:=]\s*(.*?)\s*,?\s*$/))) add(n,'configuration',m[1],'definition',m[2]);
    if(configFile && (m=line.match(/<([A-Za-z_]\w*)(?:\s+[^>]*)?>([^<]+)<\/\1>/))) add(n,'configuration',m[1],'definition',m[2]);
    if((m=line.match(/\b(?:SET|ALTER\s+SYSTEM\s+SET)\s+([\w.]+)\s*(?:=|TO)\s*(.+)/i))) add(n,'database-setting',m[1],'definition',m[2]);
    for(const q of line.matchAll(/\b(?:LIMIT|OFFSET|TOP|FETCH\s+(?:FIRST|NEXT))\s+(\d+|\$\d+|@[A-Za-z_]\w*)/gi)) add(n,'query-bound',q[0],'literal',q[0]);
    if(parameterName.test(line) && /(?:[<>]=?|==|Math\.(?:Clamp|Min|Max)|std::(?:min|max|clamp))/.test(line) && numeric.test(line))
      add(n,'threshold',`comparison:${file}:${n}`,'candidate',line.trim());
    if(kind==='documentation' && /^\s*\|/.test(line) && parameterName.test(line) && numeric.test(line))
      add(n,'documented-parameter',line.split('|').map(x=>x.trim()).find(Boolean)?.replace(/`/g,''),'documented',line.trim());
  }
}
function consume(buffer,source,file,oid=null) {
  const digest=hash(buffer);
  if(buffer.subarray(0,8192).includes(0)) { skipped.push({source:source.id,file,reason:'binary (NUL bytes)',size:buffer.length}); return; }
  const text=buffer.toString('utf8');
  if(/^version https:\/\/git-lfs.github.com\/spec\/v1/m.test(text)) { skipped.push({source:source.id,file,reason:'Git LFS pointer; payload not fetched',size:buffer.length}); return; }
  if(/-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/.test(text)) { skipped.push({source:source.id,file,reason:'private key material excluded',size:buffer.length}); return; }
  const before=rows.length;
  scan(text,source,file,digest);
  files.push({source:source.id,file,git_blob:oid,sha256:digest,bytes:buffer.length,lines:text.split('\n').length,occurrences:rows.length-before,domain:domain(file)});
}
function scanGit(source) {
  // GitHub's tree metadata supplies sizes without fetching ignored binary payloads.
  let treeFile=path.join(out,'trees',source.repository+'-'+source.revision+'.json');
  if(!fs.existsSync(treeFile))treeFile=path.join(out,'trees',source.repository+'.json');
  const metadata=fs.existsSync(treeFile)?readJson(treeFile):null;
  if(metadata?.truncated) throw Error(`GitHub tree was truncated: ${source.repository}`);
  if(metadata && !validatedTrees.has(source.repository))throw Error(`Tree metadata was not validated: ${source.repository}`);
  const tree=metadata?metadata.tree.filter(e=>e.type!=='tree').map(e=>({mode:e.mode,type:e.type,oid:e.sha,size:e.size,file:e.path})):
    git(source.path,['ls-tree','-rz',source.revision]).toString('utf8').split('\0').filter(Boolean).map(item=>{
      const m=item.match(/^(\d+) (\w+) ([a-f\d]+)\t([\s\S]+)$/);if(!m)throw Error('Unparsed tree entry');
      return {mode:m[1],type:m[2],oid:m[3],file:m[4]};
    });
  const selected=[];
  for(const item of tree) {
    const {mode,type,oid,file,size}=item;
    if(type!=='blob') { skipped.push({source:source.id,file,reason:'submodule reference',revision:oid}); continue; }
    if(binaryExtensions.test(file)) { skipped.push({source:source.id,file,reason:'binary extension'}); continue; }
    selected.push({oid,file,size});
  }
  if(!selected.length) return;
  const missing=new Set(git(source.path,['rev-list','--objects','--all','--missing=print']).toString().split('\n').filter(s=>s.startsWith('?')).map(s=>s.slice(1)));
  const wanted=[...new Set(selected.filter(e=>missing.has(e.oid)).map(e=>e.oid))];
  if(wanted.length) {
    console.log(`${source.id}: fetching ${wanted.length} required text objects in one request`);
    git(source.path,['-c','fetch.negotiationAlgorithm=noop','fetch','--quiet','origin','--no-tags','--no-write-fetch-head','--recurse-submodules=no','--filter=blob:none','--stdin'],{input:wanted.join('\n')+'\n'});
  }
  if(!metadata) {
    const sizes=git(source.path,['cat-file','--batch-check=%(objectsize)'],{input:selected.map(x=>x.oid).join('\n')+'\n'}).toString().trim().split('\n');
    for(let i=0;i<selected.length;i++) selected[i].size=Number(sizes[i]);
  }
  let batch=[], bytes=0;
  function flush() {
    if(!batch.length) return;
    let result;
    try { result=git(source.path,['cat-file','--batch'],{input:batch.map(x=>x.oid).join('\n')+'\n'}); }
    catch(e) { failures.push({source:source.id,error:'git cat-file failed',files:batch.map(x=>x.file)}); batch=[];bytes=0;return; }
    let offset=0;
    for(const entry of batch) {
      const end=result.indexOf(10,offset), header=result.subarray(offset,end).toString();
      const m=header.match(/^[a-f\d]+ blob (\d+)$/);
      if(!m) throw Error(`Unexpected object header for ${source.id}/${entry.file}`);
      const len=+m[1]; consume(result.subarray(end+1,end+1+len),source,entry.file,entry.oid); offset=end+1+len+1;
    }
    batch=[];bytes=0;
  }
  for(const file of selected) {
    if(!Number.isFinite(file.size)) { failures.push({source:source.id,file:file.file,error:'object size unavailable'});continue; }
    if(batch.length>=150||bytes+file.size>24*1024*1024) flush(); batch.push(file);bytes+=file.size;
  } flush();
}
function discover(root,depth=0,found=[]) {
  if(!fs.existsSync(root)) return found;
  if(fs.existsSync(path.join(root,'.git'))) { found.push(root); return found; }
  for(const e of fs.readdirSync(root,{withFileTypes:true})) if(e.isDirectory()&&!e.isSymbolicLink()&&!/^(?:node_modules|\.git|bin|obj|build|\.venv|\.cache)$/.test(e.name)) discover(path.join(root,e.name),depth+1,found);
  return found;
}
for(const repo of [...acquisitions].sort((a,b)=>Number(!a.name.startsWith('Laplace'))-Number(!b.name.startsWith('Laplace'))||a.name.localeCompare(b.name))) {
  if(previous&&sources.some(s=>s.id===`${repo.name}@github`))continue;
  if(repo.empty) { sources.push({id:`${repo.name}@github`,repository:repo.name,url:repo.url,scope:'github-default',empty:true});continue; }
  if(repo.exit_code!==0) { failures.push({repository:repo.name,error:repo.error});continue; }
  const source={id:`${repo.name}@github`,repository:repo.name,path:repo.path,url:repo.url,revision:repo.revision.trim(),scope:'github-default',fetched_utc:repo.fetched_utc};
  sources.push(source);scanGit(source);flushRows();database.exec('COMMIT; BEGIN;');console.log(`${source.id}: ${files.filter(f=>f.source===source.id).length} text files; ${rows.length} cumulative occurrences`);
}
const localRoots=argv.includes('--local-roots')?argv[argv.indexOf('--local-roots')+1].split(';'):[];
const explicitList=argv.includes('--repository-list')?readJson(argv[argv.indexOf('--repository-list')+1]).repositories.filter(r=>r.family&&!/[\\/](?:external|_deps)[\\/]/i.test(r.path)).map(r=>r.path):null;
const discovered=[...new Set(explicitList||localRoots.flatMap(r=>discover(r)))];
for(const [i,root] of discovered.entries()) {
  if(previous&&sources.some(s=>s.path&&path.resolve(s.path).toLowerCase()===path.resolve(root).toLowerCase()))continue;
  let remote;try {remote=git(root,['config','--get','remote.origin.url'],{stdio:['pipe','pipe','pipe']}).toString().trim();}catch{remote=null;}
  const remoteName=remote?.match(/(?:[/:])([^/]+?)(?:\.git)?$/)?.[1];
  const name=remoteName&&/laplace|hartonomous|hart-mcp/i.test(remoteName)?remoteName:path.basename(root);
  if(!explicitList&&!catalog.some(r=>r.name===name) && !/laplace|hartonomous|hart-mcp/i.test(name||'')) {discovery.push({path:root,name,status:'other repository; outside Laplace family'});continue;}
  try{git(root,['rev-parse','HEAD'],{stdio:['pipe','pipe','pipe']});}catch{discovery.push({path:root,status:'Git HEAD unavailable; not scanned'});continue;}
  const revision=git(root,['rev-parse','HEAD']).toString().trim(), status=git(root,['status','--porcelain=v1','-z']).toString().split('\0').filter(Boolean);
  let suffix=i+1;while(sources.some(s=>s.id===`${name}@local-${suffix}`))suffix++;
  const source={id:`${name}@local-${suffix}`,repository:name,path:root,url:catalog.find(r=>r.name===name)?.url||null,revision,scope:'local-checkout',dirty:status.length>0,status,scanner_sha256:scannerHash};sources.push(source);discovery.push({path:root,name,status:'scanned'});
  const names=git(root,['ls-files','-co','--exclude-standard','-z']).toString('utf8').split('\0').filter(Boolean);
  for(const file of new Set(names)) {
    const absolute=path.resolve(root,file);if(!absolute.startsWith(root+path.sep)) {failures.push({source:source.id,file,error:'path outside checkout'});continue;}
    if(!fs.existsSync(absolute)) {skipped.push({source:source.id,file,reason:'missing/deleted in checkout'});continue;}
    const stat=fs.lstatSync(absolute);if(!stat.isFile()) {skipped.push({source:source.id,file,reason:'symlink/submodule/non-file'});continue;}
    if(binaryExtensions.test(file)) {skipped.push({source:source.id,file,reason:'binary extension',size:stat.size});continue;}
    consume(fs.readFileSync(absolute),source,file);
  }
  flushRows();database.exec('COMMIT; BEGIN;');console.log(`${source.id}: ${files.filter(f=>f.source===source.id).length} text files; dirty=${source.dirty}; ${rows.length} cumulative occurrences`);
}
flushRows();fs.closeSync(jsonFile);fs.closeSync(csvFile);database.exec('COMMIT;');
const glossaryMap=new Map();
for(const row of rows) {
  const key=`${row.category}\0${row.symbol}`;
  if(!glossaryMap.has(key)) glossaryMap.set(key,{category:row.category,symbol:row.symbol,meaning_status:'unreviewed',meaning:null,repositories:new Set(),occurrences:0,definitions:0,expressions:new Set(),locations:[],source_notes:[]});
  const entry=glossaryMap.get(key);entry.repositories.add(row.repository);entry.occurrences++;
  entry.locations.push({source:row.source,file:row.file,line:row.line,role:row.role,url:row.url});
  if(row.source_note && entry.source_notes.length<20 && !entry.source_notes.some(n=>n.text===row.source_note))entry.source_notes.push({text:row.source_note,source:row.source,file:row.file,line:row.line});
  if(/definition/.test(row.role)) {entry.definitions++;if(row.expression)entry.expressions.add(row.expression);}
}
const glossary=[...glossaryMap.values()].map(e=>({...e,repositories:[...e.repositories].sort(),expressions:[...e.expressions].sort()})).sort((a,b)=>a.symbol.localeCompare(b.symbol)||a.category.localeCompare(b.category));
const variants=glossary.filter(e=>e.expressions.length>1&&['environment-candidate','configuration','database-setting','parameter'].includes(e.category));
const coverage={schema_version:1,started_utc:started,completed_utc:new Date().toISOString(),scanner_sha256:scannerHash,
  scanner_history:previous?[...(previous.scanner_history||[{sha256:previous.scanner_sha256,started_utc:previous.started_utc,completed_utc:previous.completed_utc}]),{sha256:scannerHash,started_utc:started}]:[{sha256:scannerHash,started_utc:started}],
  repository_count:catalog.length,acquired_repositories:acquisitions.filter(r=>r.exit_code===0).length,source_count:sources.length,
  text_files_scanned:files.length,occurrences:rows.length,glossary_entries:glossary.length,variant_candidates:variants.length,
  failures,skipped_count:skipped.length,sources,
  method:'Static lexical inventory of all selected tracked text at pinned GitHub default-branch revisions, plus tracked and non-ignored untracked local files. No repository code executed. Definitions, references, numeric assignments and comparisons are candidates, not proof of effective runtime values. Tests, documentation, generated and third-party files are retained and labelled.',
  limitations:['Dynamic/computed variable names and values require semantic review.','Unqualified shell variables can be process-local rather than exported environment variables.','Multiple definitions are variant candidates, not automatically conflicts.','Binary assets, private keys, LFS payloads and submodule contents are listed in skipped.json; text files have no size exclusion.','Local uncommitted content has a file SHA-256 and checkout revision; the revision alone does not identify those bytes.','This audit does not infer installation intent or prove live configuration.','Credential-bearing values and contexts are suppressed.']};
fs.writeFileSync(path.join(out,'coverage.json'),JSON.stringify(coverage,null,2)+'\n');
for(const [name,data] of Object.entries({files,glossary,variants,skipped,discovery}))writeArray(path.join(out,`${name}.json`),data);
database.exec('BEGIN; DELETE FROM glossary;');const insertTerm=database.prepare('INSERT INTO glossary VALUES(?,?,?,?)');
for(const term of glossary)insertTerm.run(term.category,term.symbol,term.occurrences,JSON.stringify(term));
database.exec('COMMIT; CREATE INDEX IF NOT EXISTS occurrence_filters ON occurrences(scope,repository,category); CREATE INDEX IF NOT EXISTS occurrence_symbol ON occurrences(symbol); CREATE INDEX IF NOT EXISTS glossary_symbol ON glossary(symbol); PRAGMA wal_checkpoint(TRUNCATE);');
database.close();
fs.writeFileSync(path.join(out,'data.js'),'window.CONFIG_AUDIT='+JSON.stringify({coverage}).replaceAll('<','\\u003c')+';\n');
fs.copyFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)),'index.html'),path.join(out,'index.html'));
console.log(JSON.stringify({repository_count:coverage.repository_count,source_count:sources.length,files:files.length,occurrences:rows.length,glossary:glossary.length,failures:failures.length,output:out}));
if(failures.length) process.exitCode=2;
