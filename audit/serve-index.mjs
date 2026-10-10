import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import {DatabaseSync} from 'node:sqlite';
const args=process.argv.slice(2),out=path.resolve(args[args.indexOf('--output')+1]||'');
if(!args.includes('--output'))throw Error('Usage: node audit/serve-index.mjs --output AUDIT_DIRECTORY');
const db=new DatabaseSync(path.join(out,'configuration.sqlite'),{readOnly:true});
const coverage=JSON.parse(fs.readFileSync(path.join(out,'coverage.json'),'utf8'));
const server=http.createServer((req,res)=>{
  const url=new URL(req.url,'http://127.0.0.1');
  res.setHeader('X-Content-Type-Options','nosniff');
  if(req.method!=='GET'){res.writeHead(405);res.end();return;}
  try{
    if(url.pathname==='/query'){
      const terms=[],values=[];
      const isEnvironment=url.searchParams.get('category')==='environment'&&db.prepare("SELECT name FROM sqlite_master WHERE name='environment_evidence'").get();
      const table=isEnvironment?'environment_evidence':'occurrences';
      for(const [key,column]of [['repo','repository'],['category','category'],['scope','scope'],['domain','domain']])if(url.searchParams.get(key)){terms.push(`${column}=?`);values.push(url.searchParams.get(key));}
      if(url.searchParams.get('role'))terms.push("role LIKE '%definition%'");
      const tokens=(url.searchParams.get('q')||'').match(/[\p{L}\p{N}]+/gu)||[];
      if(tokens.length){if(isEnvironment){for(const token of tokens){terms.push('(symbol LIKE ? OR file LIKE ? OR payload LIKE ?)');values.push('%'+token+'%','%'+token+'%','%'+token+'%');}}else{terms.push('id IN (SELECT rowid FROM occurrence_search WHERE occurrence_search MATCH ?)');values.push(tokens.map(t=>'"'+t+'"*').join(' AND '));}}
      const where=terms.length?' WHERE '+terms.join(' AND '):'',page=Math.max(0,Math.min(100000,Number(url.searchParams.get('page'))||0));
      const count=db.prepare('SELECT count(*) AS n FROM '+table+where).get(...values).n;
      const rows=db.prepare('SELECT payload FROM '+table+where+' ORDER BY id LIMIT 100 OFFSET ?').all(...values,page*100).map(x=>JSON.parse(x.payload));
      res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({count,rows,page}));return;
    }
    if(url.pathname==='/term'){
      const terms=db.prepare('SELECT payload FROM glossary WHERE symbol=? ORDER BY category').all(url.searchParams.get('symbol')||'').map(r=>JSON.parse(r.payload));
      if(db.prepare("SELECT name FROM sqlite_master WHERE name='environment_contracts'").get()){
        const contract=db.prepare('SELECT payload FROM environment_contracts WHERE symbol=?').get(url.searchParams.get('symbol')||'');
        if(contract){const c=JSON.parse(contract.payload),e=c.evidence;terms.unshift({category:'environment source contract',meaning:c.meaning_status,occurrences:e.length,definitions:e.filter(r=>r.role==='definition').length,repositories:[...new Set(e.map(r=>r.repository))],expressions:[...new Set(e.map(r=>r.kind+': '+r.expression))],source_notes:e.filter(r=>r.source_comment).map(r=>({...r,text:r.source_comment})),locations:e});}
      }
      res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify(terms));return;
    }
    const files=new Set(['index.html','data.js','coverage.json','glossary.json','variants.json','occurrences.csv','occurrences.jsonl','files.json','skipped.json','discovery.json','configuration.sqlite','reviewed-glossary.json','environment-glossary.json','environment-contracts.json','environment-contracts.csv','configuration-review.json','repository-index.json','findings.json']);
    const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
    if(!files.has(name)||!fs.existsSync(path.join(out,name))){res.writeHead(404);res.end('Not found');return;}
    const type=name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.js')?'text/javascript; charset=utf-8':name.endsWith('.json')?'application/json':name.endsWith('.csv')?'text/csv; charset=utf-8':'application/octet-stream';
    res.writeHead(200,{'Content-Type':type});fs.createReadStream(path.join(out,name)).pipe(res);
  }catch(e){res.writeHead(500,{'Content-Type':'application/json'});res.end(JSON.stringify({error:String(e.message)}));}
});
server.listen(args.includes('--port')?Number(args[args.indexOf('--port')+1]):0,'127.0.0.1',()=>{const url=`http://127.0.0.1:${server.address().port}/`;fs.writeFileSync(path.join(out,'viewer.json'),JSON.stringify({url,pid:process.pid,started_utc:new Date().toISOString(),repository_count:coverage.repository_count},null,2));console.log(url);});
