import fs from 'node:fs';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
const args=process.argv.slice(2),out=path.resolve(args[args.indexOf('--output')+1]||'');
if(!args.includes('--output'))throw Error('Usage: node audit/review-configuration.mjs --output AUDIT_DIRECTORY');
const db=new DatabaseSync(path.join(out,'configuration.sqlite'));
const inputCoverage=JSON.parse(fs.readFileSync(path.join(out,'coverage.json'),'utf8'));
const reviewedRevisions={Laplace:'58cab06ee7b460949cb2164cb29b7e24df50c8a5','Laplace-Operations':'9382f00aa1fd900274fbfae816195d7dd777cb2a','Laplace-Engine':'bde37b928b34e1e5da500eeb77d418019c82a48e','Laplace-MCP':'d7fbc1d89035c1e51e59153f5ca3fa9561e7a6ab','Laplace-Native':'1b9367c8055cdbd79beb1a8ba4c2d1aa322e4678'};
const reviewApplies=Object.entries(reviewedRevisions).every(([name,revision])=>inputCoverage.sources.some(s=>s.repository===name&&s.scope==='github-default'&&s.revision===revision));
const meanings={
 LAPLACE_MACHINE_ENV:'Windows override for the installation declaration file read by Operations. Its use must be checked per entry point; the pinned monorepo CMD script does not read that file.',
 LAPLACE_SRC:'Operations root for the sibling source repositories. This is source location, not an installed application or database directory.',
 LAPLACE_BUILD:'Operations parent directory for native and dependency build trees. The monorepo also has a separate LAPLACE_BUILD_ROOT contract.',
 LAPLACE_BUILD_ROOT:'Monorepo Windows root for managed outputs and native build directories. It is independently defaulted by env.cmd and app/Directory.Build.props.',
 LAPLACE_ENGINE_BUILD:'The monorepo native engine build directory. Consumers use its libraries and generated perfcaches; it is not the modular Engine executable path.',
 LAPLACE_DATA_ROOT:'An overloaded root. Windows env.cmd derives build, deployment, dependency and external-source paths from it; Linux site.sh can derive it from the corpus root. It does not have one consistent meaning across these entry points.',
 LAPLACE_WORK:'Operations generated working data and logs root, also used to derive prepared artifacts and operation state. Whether a child is disposable depends on its consumer.',
 LAPLACE_DATA:'Operations input corpus root. It is distinct from the PostgreSQL cluster directory and the source repositories.',
 LAPLACE_DEPSRC:'Source location for third-party dependencies used by native builds.',
 LAPLACE_DEPS:'Operations installed dependency prefixes, distinct from dependency sources and temporary build trees.',
 LAPLACE_DEPS_PREFIX:'Monorepo dependency installation prefix used by its build scripts; it is a separate contract from Operations LAPLACE_DEPS.',
 LAPLACE_DEPLOY:'Monorepo Windows deployment prefix, including its native extension libraries.',
 LAPLACE_INSTALL_PREFIX:'Monorepo Linux installed runtime prefix. A default path in source does not prove which filesystem backs the live installation.',
 LAPLACE_PGDATA:'PostgreSQL cluster data directory. A declared path alone does not prove a cluster exists there.',
 LAPLACE_PGWAL:'PostgreSQL write-ahead-log directory. A distinct path or drive letter alone does not establish dedicated storage.',
 LAPLACE_PG_DIR:'Operations PostgreSQL binary installation prefix. This is not PGDATA.',
 LAPLACE_PG_PREFIX:'Monorepo PostgreSQL binary/development prefix; several Linux scripts also accept Operations LAPLACE_PG_DIR.',
 LAPLACE_PGUSER:'Conflicting identities: Operations setup uses it as the operating-system PostgreSQL service account, while monorepo Windows env.cmd uses it as the database login in the application connection string.',
 LAPLACE_ROLE:'Operations database role used in client connection information and database access provisioning. Distinct from the service operating-system identity.',
 LAPLACE_PGHOST:'PostgreSQL connection host or, on Unix, socket directory. It selects a connection target; it does not establish database compatibility.',
 LAPLACE_PGPORT:'PostgreSQL connection/listener port used by the consuming script or service.',
 LAPLACE_CONNINFO:'libpq connection information used by the modular Engine/Operations path. Credential-bearing source context is omitted from exported evidence.',
 LAPLACE_DB:'Monorepo knowledge-database connection string consumed by managed code. Credential-bearing source context is omitted from exported evidence.',
 LAPLACE_APP_DB:'Monorepo connection string for application-owned state such as accounts and billing, separate from the selected knowledge database when configured.',
 LAPLACE_PG_RESERVED:'Operations memory reservation for other host residents, subtracted when planning PostgreSQL. The pinned Windows default encodes a past 34 GB resident-workload measurement.',
 LAPLACE_PG_BUFFERS_MAX:'Optional Operations cap on shared_buffers, used for a measured constraint of a PostgreSQL build. The pinned Windows environment supplies a 1 GB cap.',
 LAPLACE_PG_SERVING:'Operations declared serving-connection allowance in its PostgreSQL resource plan. Its default equation differs from the monorepo managed resource plan.',
 LAPLACE_BATCH_MB:'Modular Engine ingest byte budget expressed in MiB: src/ingest.c shifts the integer left by 20. The native fallback is 1024; Operations Windows supplies 256. This is override layering, not by itself a defect.',
 LAPLACE_NATIVE_THREADS:'Native compute thread budget used by managed runtime environment setup and native consumers. Windows shell defaults and managed topology-driven assignment are separate sources.',
 MKL_NUM_THREADS:'Intel MKL thread setting. Laplace NativeRuntimeEnv assigns a topology-derived count; Windows env.cmd also provides a fixed shell fallback.',
 TBB_NUM_THREADS:'TBB thread setting assigned by Laplace runtime environment setup, with an independent Windows shell fallback.',
 MKL_DYNAMIC:'MKL dynamic-thread behavior setting. NativeRuntimeEnv explicitly sets it to zero.',
 DOTNET_GCHeapCount:'Managed GC heap count. NativeRuntimeEnv derives a value from topology while the Windows shell also sets a fallback.',
 CMAKE_BUILD_PARALLEL_LEVEL:'Build parallelism exposed through CMake. The pinned monorepo Windows environment provides a fixed fallback; it is not the PostgreSQL query-worker count.',
 LAPLACE_ISA:'Native runtime instruction-set override. Native API documentation states that it may lower the dispatch level; CI uses it to exercise supported dispatch paths.',
 LAPLACE_TIMING:'Presence-controlled modular Engine timing diagnostics, read by getenv in structure.c.',
 LAPLACE_MCP_PORT:'Native Laplace-MCP listener port, selected from an explicit serve argument, then the environment, then the configured build default.',
 LAPLACE_MCP_HOST:'Native Laplace-MCP bind host, selected from an explicit serve argument, then the environment, then the configured build default.',
 LAPLACE_VOLUMES:'Operations storage-provisioning declarations, including volume group, logical volume, size, filesystem and mountpoint. The pinned Linux environment contains host-specific fallback declarations.',
 LAPLACE_OPERATIONS:'Location of the Operations source checkout selected by consuming builds/scripts. It should not be confused with an installed runtime release.',
 LAPLACE_DEVSHELL:'Operations Windows developer-shell script responsible for locating and importing the compiler/toolchain environment.',
 LAPLACE_ENV_LOADED:'Monorepo Windows process marker that prevents env.cmd from resolving the environment again within the same process chain.',
 ServingCommandTimeoutSeconds:'Monorepo serving-command timeout ceiling, 120 seconds at the audited revision. LaplaceDataSource applies the serving policy separately from ingest.'
};
const directEnv=(r)=>{
 const s=r.snippet,n=r.symbol.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
 if(new RegExp('\\b(?:getenv|secure_getenv|GetEnvironmentVariable|os\\.getenv|os\\.environ\\.get|env::var|SetThreadVar)\\s*\\(\\s*["\']'+n+'["\']').test(s))return 'reader/helper';
 if(new RegExp('(?:process\\.env\\.'+n+'\\b|(?:os\\.)?environ\\s*\\[\\s*["\']'+n+'["\'])').test(s))return 'environment accessor';
 if(new RegExp('(?:\\$env:'+n+'\\b|\\bSet-Default\\s+'+n+'\\b|\\bexport\\s+'+n+'\\b|\\bset\\s+"?'+n+'=)','i').test(s))return 'process assignment/reference';
 if(/\.(?:cmd|bat)$/i.test(r.file)&&new RegExp('%'+r.symbol+'%').test(s))return 'CMD environment expansion';
 if(/(?:\.env(?:\.|$)|^laplace\.env$)/i.test(r.file)&&new RegExp('^\\s*(?:export\\s+)?'+r.symbol+'=').test(s))return 'environment declaration';
 if(new RegExp('\\$ENV\\{'+r.symbol+'\\}').test(s))return 'CMake environment read';
 return null;
};
db.exec('DROP TABLE IF EXISTS environment_terms; CREATE TABLE environment_terms(symbol TEXT PRIMARY KEY,payload TEXT);');
const environments=new Map();
for(const item of db.prepare("SELECT payload FROM occurrences WHERE category='environment'").iterate()){
 const row=JSON.parse(item.payload),evidence=directEnv(row);if(!evidence)continue;
 if(!environments.has(row.symbol))environments.set(row.symbol,{symbol:row.symbol,evidence:[],meaning:reviewApplies?meanings[row.symbol]||null:null});
 const term=environments.get(row.symbol);
 if(term.evidence.length<100)term.evidence.push({kind:evidence,source:row.source,file:row.file,line:row.line,domain:row.domain,url:row.url});
}
const insertEnv=db.prepare('INSERT INTO environment_terms VALUES(?,?)');db.exec('BEGIN;');
for(const entry of environments.values())insertEnv.run(entry.symbol,JSON.stringify(entry));
const reviewed=[];const update=db.prepare('UPDATE glossary SET payload=? WHERE category=? AND symbol=?');
for(const [symbol,meaning]of Object.entries(reviewApplies?meanings:{})){
 const entries=db.prepare('SELECT payload FROM glossary WHERE symbol=?').all(symbol).map(r=>JSON.parse(r.payload));
 if(!entries.length)continue;
 for(const entry of entries){entry.meaning=meaning;entry.meaning_status='source-reviewed';update.run(JSON.stringify(entry),entry.category,symbol);}
 reviewed.push({symbol,meaning,evidence:entries.flatMap(e=>e.locations).filter(l=>l.source.endsWith('@github')).slice(0,30)});
}
db.exec('COMMIT;');
const refs=(repo,file,symbol)=>db.prepare('SELECT payload FROM occurrences WHERE repository=? AND scope=? AND file=? AND symbol=? ORDER BY id LIMIT 5').all(repo,'github-default',file,symbol).map(x=>{const r=JSON.parse(x.payload);return {repository:r.repository,revision:r.revision,file:r.file,line:r.line,snippet:r.snippet,url:r.url};});
const findings=reviewApplies?[
 {id:'IDENTITY-NAME-COLLISION',classification:'verified contract mismatch',finding:'LAPLACE_PGUSER names an OS service account in Operations and a database login in monorepo Windows configuration.',evidence:[...refs('Laplace-Operations','laplace.env.ps1','LAPLACE_PGUSER'),...refs('Laplace','scripts/win/env.cmd','LAPLACE_PGUSER')]},
 {id:'WINDOWS-CONFIG-READERS',classification:'verified independent configuration sources',finding:'Operations reads the Windows machine declaration; pinned monorepo env.cmd and MSBuild provide independent path defaults. This establishes a reader/configuration mismatch, not a claim that differently named directories are intrinsically wrong.',evidence:[...refs('Laplace-Operations','laplace.env.ps1','LAPLACE_MACHINE_ENV'),...refs('Laplace','scripts/win/env.cmd','LAPLACE_DATA_ROOT'),...refs('Laplace','app/Directory.Build.props','LAPLACE_BUILD_ROOT')]},
 {id:'RESOURCE-CONNECTION-EQUATIONS',classification:'verified different planning equations',finding:'Operations knowledge-profile serving allowance defaults to four times logical threads, while PostgresResourcePlan uses logical processors and also includes separate fold headroom. Applied live budgets and aggregate service pools still require operational validation.',evidence:[...refs('Laplace-Operations','tune-pg.sh','LAPLACE_PG_SERVING'),...refs('Laplace','app/Laplace.Core/Core/PostgresResourcePlan.cs','servingConnections'),...refs('Laplace','app/Laplace.Core/Core/PostgresResourcePlan.cs','foldPoolHeadroom')]},
 {id:'INGEST-BATCH-LAYERING',classification:'verified override layering; not automatically a defect',finding:'The modular Engine native fallback is 1024 MiB; Operations Windows supplies 256 MiB. The consuming calculation establishes the unit, despite the variable spelling MB.',evidence:[...refs('Laplace-Engine','src/ingest.c','LAPLACE_BATCH_MB'),...refs('Laplace-Operations','laplace.env.ps1','LAPLACE_BATCH_MB')]},
 {id:'WINDOWS-RESIDENT-MEMORY-DEFAULT',classification:'verified host-specific historical default',finding:'Operations Windows embeds a 34 GB reservation justified by an October 5 llama-service measurement in its source comment. This audit does not establish whether that workload is currently resident.',evidence:refs('Laplace-Operations','laplace.env.ps1','LAPLACE_PG_RESERVED')},
 {id:'STORAGE-PROVISIONING-DEFAULTS',classification:'verified host-specific fallback declarations',finding:'The Linux environment contains fallback LVM provisioning declarations. Whether a particular invocation created a volume cannot be established from those declarations alone.',evidence:refs('Laplace-Operations','laplace.env','LAPLACE_VOLUMES')}
]:[];
fs.writeFileSync(path.join(out,'reviewed-glossary.json'),JSON.stringify(reviewed,null,2)+'\n');
fs.writeFileSync(path.join(out,'findings.json'),JSON.stringify(findings,null,2)+'\n');
fs.writeFileSync(path.join(out,'environment-glossary.json'),JSON.stringify([...environments.values()].sort((a,b)=>a.symbol.localeCompare(b.symbol)),null,2)+'\n');
// Stream the updated complete glossary; the historical index exceeds one JS string.
const fd=fs.openSync(path.join(out,'glossary.json'),'w');fs.writeSync(fd,'[\n');let first=true;
for(const row of db.prepare('SELECT payload FROM glossary ORDER BY symbol,category').iterate()){fs.writeSync(fd,(first?'':',\n')+row.payload);first=false;}
fs.writeSync(fd,'\n]\n');fs.closeSync(fd);
const coverage=JSON.parse(fs.readFileSync(path.join(out,'coverage.json'),'utf8'));
coverage.environment_names_with_direct_evidence=environments.size;coverage.source_reviewed_terms=reviewed.length;coverage.reviewed_findings=findings.length;
coverage.semantic_review={status:reviewApplies?'applies to pinned source revisions':'pending: source revisions differ from reviewed snapshot',revisions:reviewedRevisions};
coverage.limitations.push('The broad environment category includes lexical name references; environment-glossary.json separates names with a direct reader, process assignment, or declaration. It does not prove export scope or effective live values for every occurrence.');
fs.writeFileSync(path.join(out,'coverage.json'),JSON.stringify(coverage,null,2)+'\n');
fs.writeFileSync(path.join(out,'data.js'),'window.CONFIG_AUDIT='+JSON.stringify({coverage}).replaceAll('<','\\u003c')+';\n');
db.exec('PRAGMA wal_checkpoint(TRUNCATE);');db.close();
console.log(JSON.stringify({environment_names:environments.size,source_reviewed_terms:reviewed.length,findings:findings.length}));
