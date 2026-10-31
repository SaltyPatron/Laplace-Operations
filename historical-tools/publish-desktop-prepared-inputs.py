from pathlib import Path
import hashlib, importlib.util, json, os, shutil, subprocess, tempfile, zipfile
audit=Path(__file__).resolve().parent
source=audit/'qualified-native-inputs'
target=Path(r'E:/Data/Laplace/work/tier0').resolve()
assert target==Path(r'E:/Data/Laplace/work/tier0')
for path in (target,*target.parents,source,*source.parents):
 assert not path.is_symlink() and not path.is_junction(),str(path)
references=json.loads((audit/'desktop-database-cache-references.json').read_text(encoding='utf-8-sig'))
assert all(not Path(p).resolve().is_relative_to(target) for p in references)
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
manifest=json.loads((source/'manifest.json').read_text())
for name,record in manifest.items():
 assert name in ('tier0.bin','tier0.flags','tier0.flags.layout','tier0.highway')
 assert (source/name).stat().st_size==record['bytes'] and sha(source/name)==record['sha256']
assert manifest['tier0.bin']['bytes']==1114112*64
engine=Path(r'D:/Libraries/build/Laplace/Laplace/build-win/core/recipe_engine/laplace.exe')
env=dict(os.environ,LAPLACE_TIER0=str(source/'tier0.bin'),LAPLACE_FLAGS=str(source/'tier0.flags'),
 LAPLACE_HIGHWAY=str(source/'tier0.highway'),LAPLACE_MANIFEST=r'E:/Repositories/Laplace/Laplace-Native/manifest',
 LAPLACE_CONNINFO='host=127.0.0.1 port=1 connect_timeout=1 dbname=unused')
with tempfile.TemporaryDirectory(prefix='prepared-verification-',dir=audit) as temporary:
 work=Path(temporary).resolve();assert work.parent==audit and not work.is_junction()
 generated=work/'highway.bin'
 result=subprocess.run([str(engine),'highway','-o',str(generated)],env=env,capture_output=True,text=True,check=True)
 assert generated.is_file()
 fingerprints=[subprocess.run([str(engine),'highway','--fingerprint','-o',str(p)],env=env,capture_output=True,text=True,check=True).stdout.strip() for p in (source/'tier0.highway',generated)]
 assert fingerprints[0]==fingerprints[1],fingerprints
before={p.name:dict(sha256=sha(p),bytes=p.stat().st_size) for p in target.iterdir() if p.is_file()}
backup=audit/'desktop-prepared-before-full-floor.zip'
assert not backup.exists(),'Do not overwrite the original prepared-input backup'
with zipfile.ZipFile(backup,'x',zipfile.ZIP_DEFLATED,compresslevel=1) as z:
 for name in before:z.write(target/name,name)
with zipfile.ZipFile(backup) as z:
 assert set(z.namelist())==set(before)
 for name,record in before.items():
  with z.open(name) as f:assert hashlib.file_digest(f,'sha256').hexdigest()==record['sha256']
spec=importlib.util.spec_from_file_location('store',r'E:/Repositories/Laplace/Laplace-Operations/installation/artifact_store.py')
store=importlib.util.module_from_spec(spec);spec.loader.exec_module(store)
with store.store_lock(Path(r'E:/Data/Laplace/work/artifacts/windows-components')):
 for name in manifest:
  temporary=target/(name+'.full-floor-new')
  assert not temporary.exists()
  shutil.copy2(source/name,temporary)
  assert sha(temporary)==manifest[name]['sha256']
  os.replace(temporary,target/name)
 # These are obsolete dumps from the previous Highway writer, not runtime inputs.
 for name in ('tier0.highway.keys','tier0.highway.layout','tier0.highway.nodes'):
  p=target/name
  if p.exists():
   assert p.resolve().parent==target and sha(p)==before[name]['sha256']
   p.unlink()
after={name:dict(sha256=sha(target/name),bytes=(target/name).stat().st_size) for name in manifest}
assert after==manifest
receipt=dict(status='passed',scope='desktop prepared build inputs',target=str(target),before=before,
 after=after,backup=str(backup),database_references=references,highway_fingerprint=fingerprints[0])
(audit/'desktop-prepared-input-repair.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'status':'passed','records':1114112,'target':str(target),'backup':str(backup)}))
