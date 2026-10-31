from pathlib import Path
import subprocess,json,datetime
root=Path(r'E:/Repositories/Laplace')
retired=[]
def git(repo,*args,check=True):
 return subprocess.run(['git','-C',str(repo),*args],capture_output=True,text=True,encoding='utf-8',check=check)
for repo in sorted(root.iterdir()):
 if not (repo/'.git').is_dir(): continue
 git(repo,'fetch','origin','--prune','--tags')
 main=git(repo,'rev-parse','origin/main').stdout.strip()
 current=git(repo,'branch','--show-current').stdout.strip()
 rows=git(repo,'for-each-ref','--format=%(refname) %(objectname)','refs/heads','refs/remotes/origin').stdout.splitlines()
 for row in rows:
  ref,sha=row.split()
  remote=ref.startswith('refs/remotes/origin/')
  name=ref.removeprefix('refs/remotes/origin/' if remote else 'refs/heads/')
  if name in ('main','HEAD') or (repo.name=='Laplace-Operations' and name=='fingerprints'):continue
  if not remote and name==current:continue
  if git(repo,'merge-base','--is-ancestor',sha,main,check=False).returncode:continue
  if remote:
   git(repo,'push','origin','--force-with-lease=refs/heads/'+name+':'+sha,':refs/heads/'+name)
  else:
   git(repo,'update-ref','-d',ref,sha)
  retired.append(dict(repo=repo.name,ref=ref,sha=sha,main=main,proof='ancestor of origin/main'))
out=root/'artifacts/repository-cleanup-2026-10-31T04-53-01-772Z/merged-branch-retirement-current.json'
prior=json.loads(out.read_text()) if out.exists() else []
out.write_text(json.dumps(prior+retired,indent=2)+'\n')
print(json.dumps(retired,indent=2))
