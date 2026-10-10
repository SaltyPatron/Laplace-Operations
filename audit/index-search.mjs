import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
const args=process.argv.slice(2),out=path.resolve(args[args.indexOf('--output')+1]||'');
if(!args.includes('--output'))throw Error('Usage: node audit/index-search.mjs --output AUDIT_DIRECTORY');
const db=new DatabaseSync(path.join(out,'configuration.sqlite'));
db.exec(`DROP TABLE IF EXISTS occurrence_search;
CREATE VIRTUAL TABLE occurrence_search USING fts5(symbol,file,context,content='',detail=none);
INSERT INTO occurrence_search(rowid,symbol,file,context)
 SELECT id,replace(symbol,'_',' '),file,replace(json_extract(payload,'$.snippet'),'_',' ') FROM occurrences;`);
const indexed=db.prepare('SELECT count(*) AS n FROM occurrence_search').get().n;
const expected=db.prepare('SELECT count(*) AS n FROM occurrences').get().n;
if(indexed!==expected)throw Error('Full-text index lost occurrences');
db.exec('PRAGMA wal_checkpoint(TRUNCATE);');db.close();
console.log(`Full-text search indexed ${indexed} occurrences.`);
