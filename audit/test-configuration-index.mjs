import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const tools=path.dirname(fileURLToPath(import.meta.url));
const root=fs.mkdtempSync(path.join(os.tmpdir(),'laplace-config-index-'));
const repo=path.join(root,'Fixture'),output=path.join(root,'output');
fs.mkdirSync(repo);fs.mkdirSync(output);
const git=(...args)=>execFileSync('git',['-C',repo,...args],{encoding:'utf8',stdio:['pipe','pipe','pipe']});
try {
  git('init');git('config','user.name','Configuration fixture');git('config','user.email','fixture@example.invalid');git('remote','add','origin','https://github.com/Fixture/Fixture.git');
  const fixtures={
    'settings.ps1':'# Number of records in one admission batch.\n$env:LAPLACE_BATCH_SIZE = 128\nSet-Default LAPLACE_WORK "Z:\\a directory\\work"\n',
    'native.c':'#define CAPACITY 4096\n#define LAPLACE_HEADER_H\nconst unsigned chunk_size = 1024;\ngetenv("OMP_NUM_THREADS");\nprintf("%s_%u");\n',
    'runtime.cs':'var n = Environment.GetEnvironmentVariable(\n "LAPLACE_NATIVE_THREADS");\nconst int poolLimit = 16;\n',
    'settings.json':'{"password":"AUDIT_SECRET_CANARY_NEVER_EXPORT", "maxConnections":32}\n',
    'queries.sql':'SET work_mem = \'64MB\';\nSELECT x FROM y LIMIT 42;\n',
    'settings.weird':'LAPLACE_TEST_UNUSUAL=71\n',
    'pointer.lfs':'version https://git-lfs.github.com/spec/v1\noid sha256:'+'a'.repeat(64)+'\nsize 100\n',
    'notes.md':'`LAPLACE_BATCH_SIZE` controls the records per batch.\n',
    'binary.dat':'abc\0def'
  };
  for(const [name,text] of Object.entries(fixtures))fs.writeFileSync(path.join(repo,name),text);
  git('add','.');git('commit','-m','Fixture');const revision=git('rev-parse','HEAD').trim();
  fs.appendFileSync(path.join(repo,'settings.ps1'),'$env:LAPLACE_LOCAL_ONLY = 77\n');
  fs.writeFileSync(path.join(output,'catalog.json'),JSON.stringify([{name:'Fixture',url:'https://github.com/Fixture/Fixture'}]));
  fs.writeFileSync(path.join(output,'acquisition.json'),JSON.stringify([{name:'Fixture',url:'https://github.com/Fixture/Fixture',path:repo,revision,exit_code:0}]));
  execFileSync(process.execPath,[path.join(tools,'configuration-index.mjs'),'--output',output,'--local-roots',root],{stdio:'pipe'});
  const rows=fs.readFileSync(path.join(output,'occurrences.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
  for(const symbol of ['LAPLACE_BATCH_SIZE','LAPLACE_WORK','OMP_NUM_THREADS','LAPLACE_NATIVE_THREADS','CAPACITY','chunk_size','poolLimit','work_mem','LIMIT 42','LAPLACE_TEST_UNUSUAL'])assert(rows.some(r=>r.symbol===symbol),`Missing ${symbol}`);
  assert(rows.some(r=>r.symbol==='LAPLACE_NATIVE_THREADS'&&r.line===2),'Multiline reader must cite literal line');
  assert(!rows.some(r=>r.symbol==='LAPLACE_LOCAL_ONLY'&&r.scope==='github-default'),'Uncommitted data leaked into pinned scope');
  assert(rows.some(r=>r.symbol==='LAPLACE_LOCAL_ONLY'&&r.scope==='local-checkout'),'Local change was omitted');
  for(const name of ['occurrences.jsonl','occurrences.csv','glossary.json','data.js'])assert(!fs.readFileSync(path.join(output,name),'utf8').includes('AUDIT_SECRET_CANARY_NEVER_EXPORT'),`Secret leaked in ${name}`);
  const skipped=JSON.parse(fs.readFileSync(path.join(output,'skipped.json')));
  assert(skipped.some(s=>s.file==='binary.dat'&&s.reason.includes('binary')));
  assert(skipped.some(s=>s.file==='pointer.lfs'&&s.reason.includes('LFS')));
  assert(rows.filter(r=>r.scope==='github-default').every(r=>r.url.includes(revision)&&r.content_sha256.length===64));
  const before=rows.length;
  execFileSync(process.execPath,[path.join(tools,'configuration-index.mjs'),'--append','--output',output,'--local-roots',root],{stdio:'pipe'});
  assert.equal(fs.readFileSync(path.join(output,'occurrences.jsonl'),'utf8').trim().split('\n').length,before,'Append duplicated existing snapshots');
  execFileSync(process.execPath,[path.join(tools,'review-configuration.mjs'),'--output',output],{stdio:'pipe'});
  const environments=JSON.parse(fs.readFileSync(path.join(output,'environment-glossary.json'),'utf8'));
  assert(environments.some(e=>e.symbol==='OMP_NUM_THREADS'),'Direct native environment reader missing');
  assert(!environments.some(e=>['s','s_','u','LAPLACE_HEADER_H'].includes(e.symbol)),'Compile guards or printf tokens labelled as environment readers');
  assert.equal(JSON.parse(fs.readFileSync(path.join(output,'reviewed-glossary.json'),'utf8')).length,0,'Manual review was wrongly applied to unrelated revisions');
  execFileSync(process.execPath,[path.join(tools,'index-search.mjs'),'--output',output],{stdio:'pipe'});
  console.log('PASS environment readers, multiline provenance, paths, named constants, SQL settings/bounds, uncommon extensions, local changes, credential suppression and explicit binary/LFS omissions');
} finally {
  const parent=path.resolve(os.tmpdir())+path.sep;
  if(!path.resolve(root).startsWith(parent)||!path.basename(root).startsWith('laplace-config-index-'))throw Error('Cleanup path escaped fixture root');
  fs.rmSync(root,{recursive:true,force:true});
}
