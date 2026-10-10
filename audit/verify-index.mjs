import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
const args=process.argv.slice(2),out=path.resolve(args[args.indexOf('--output')+1]||'');
if(!args.includes('--output'))throw Error('Usage: node audit/verify-index.mjs --output AUDIT_DIRECTORY');
const read=name=>JSON.parse(fs.readFileSync(path.join(out,name),'utf8').replace(/^\uFEFF/,''));
const coverage=read('coverage.json'),files=read('files.json'),skipped=read('skipped.json'),sources=new Map(coverage.sources.map(s=>[s.id,s]));
const db=new DatabaseSync(path.join(out,'configuration.sqlite'),{readOnly:true});
assert.equal(db.prepare('SELECT count(*) n FROM occurrences').get().n,coverage.occurrences);
assert.equal(db.prepare('SELECT count(*) n FROM glossary').get().n,coverage.glossary_entries);
assert.equal(db.prepare('SELECT count(*) n FROM occurrence_search').get().n,coverage.occurrences);
assert.equal(coverage.failures.length,0);
let localDiscovery=null;
if(fs.existsSync(path.join(out,'repository-discovery.json'))){
 const discovery=read('repository-discovery.json');
 const normalize=p=>path.resolve(p).replaceAll('\\','/').toLowerCase();
 const captured=new Set(coverage.sources.filter(s=>s.scope==='local-checkout').map(s=>normalize(s.path)));
 const expected=discovery.repositories.filter(r=>r.family);
 for(const repo of expected){assert(repo.revision,`Unreadable repository revision: ${repo.path}`);assert(captured.has(normalize(repo.path)),`Unscanned local repository: ${repo.path}`);}
 const unreadable=discovery.omissions.filter(o=>o.reason==='directory not readable');
 assert.equal(unreadable.length,0,'Local discovery has unreadable directories');
 localDiscovery={roots:discovery.roots,depth_limit:discovery.depth_limit,family_repositories:expected.length,unreadable_directories:unreadable.length};
}
const byFile=new Map(files.map(f=>[f.source+'\0'+f.file,f]));
let reconciled=0;
for(const source of sources.values()){
 if(source.scope!=='github-default'||source.empty)continue;
 const names=[`trees/${source.repository}-${source.revision}.json`,`trees/${source.repository}.json`];
 const tree=read(names.find(n=>fs.existsSync(path.join(out,n))));assert(!tree.truncated);
 const expected=tree.tree.filter(e=>e.type!=='tree').length;
 const actual=files.filter(f=>f.source===source.id).length+skipped.filter(f=>f.source===source.id).length;
 assert.equal(actual,expected,`Unaccounted tree entries: ${source.id}`);reconciled++;
}
const samples=[],drift=[],cache=new Map();
for(const group of db.prepare('SELECT source,min(id) first,max(id) last,count(*) n FROM occurrences GROUP BY source').iterate()){
 for(const id of new Set([group.first,group.first+Math.floor((group.n-1)/2),group.last])){
  const row=JSON.parse(db.prepare('SELECT payload FROM occurrences WHERE id=?').get(id).payload),source=sources.get(row.source),key=row.source+'\0'+row.file;
  assert.equal(row.content_sha256,byFile.get(key).sha256,'Row/file digest mismatch');
  if(!cache.has(key)){
   const content=source.scope==='github-default'?execFileSync('git',['-C',source.path,'show',source.revision+':'+row.file],{maxBuffer:256*1024*1024}):fs.readFileSync(path.join(source.path,row.file));
   cache.set(key,{sha:crypto.createHash('sha256').update(content).digest('hex'),lines:content.toString('utf8').split(/\r?\n/).length});
  }
  const actual=cache.get(key);
  if(actual.sha!==row.content_sha256){assert.equal(source.scope,'local-checkout','Pinned Git source changed');drift.push({source:row.source,file:row.file,expected:row.content_sha256,now:actual.sha});continue;}
  assert(row.line>=1&&row.line<=actual.lines,'Invalid source line');
  if(source.scope==='github-default')assert(row.url.includes('/blob/'+source.revision+'/'));
  samples.push({source:row.source,file:row.file,line:row.line,sha256:actual.sha});
 }
}
for(const finding of read('findings.json'))assert(finding.evidence.length>0,`Uncited finding: ${finding.id}`);
const timing=[];
if(fs.existsSync(path.join(out,'viewer.json'))){
 const base=read('viewer.json').url;
 for(const q of ['LAPLACE_PGUSER','LAPLACE_BATCH_MB','max_connections']){
  const start=performance.now(),response=await fetch(base+'query?scope=github-default&q='+encodeURIComponent(q));
  assert(response.ok);const result=await response.json();assert(result.count>0);assert(result.rows.length<=100);
  timing.push({query:q,count:result.count,milliseconds:Math.round(performance.now()-start)});
 }
}
db.close();
const receipt={verified_utc:new Date().toISOString(),repository_trees_reconciled:reconciled,local_discovery:localDiscovery,empty_repositories:coverage.sources.filter(s=>s.empty).map(s=>s.repository),file_count:files.length,occurrences:coverage.occurrences,source_samples:samples,local_drift:drift,search_timings:timing,verdict:drift.length?'passed with local changes after snapshot':'passed'};
fs.writeFileSync(path.join(out,'verification.json'),JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify({trees:reconciled,samples:samples.length,local_drift:drift.length,search_timings:timing,verdict:receipt.verdict}));
