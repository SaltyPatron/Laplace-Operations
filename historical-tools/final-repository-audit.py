from pathlib import Path
import datetime,json,subprocess
root=Path(r'E:/Repositories/Laplace')
def git(repo,*args):
 return subprocess.run(['git','-C',str(repo),*args],capture_output=True,text=True,encoding='utf-8',check=True).stdout.strip()
result=[]
for repo in sorted(root.iterdir()):
 if not (repo/'.git').is_dir():continue
 git(repo,'fetch','origin','--prune','--tags')
 assert not git(repo,'status','--porcelain','--untracked-files=all'),repo
 assert git(repo,'branch','--show-current')=='main',repo
 git(repo,'pull','--ff-only')
 head=git(repo,'rev-parse','HEAD');remote=git(repo,'rev-parse','origin/main')
 assert head==remote,(repo,head,remote)
 local=git(repo,'for-each-ref','--format=%(refname:short)','refs/heads').splitlines()
 assert local==['main'],(repo,local)
 heads=dict(line.split()[::-1] for line in git(repo,'ls-remote','--heads','origin').splitlines())
 allowed={'refs/heads/main'}|({'refs/heads/fingerprints'} if repo.name=='Laplace-Operations' else set())
 assert set(heads)==allowed,(repo,heads)
 remote_tags=dict(line.split()[::-1] for line in git(repo,'ls-remote','--tags','origin').splitlines())
 local_tags=dict(line.split() for line in git(repo,'for-each-ref','--format=%(refname) %(objectname)','refs/tags').splitlines())
 assert all(remote_tags.get(ref)==sha for ref,sha in local_tags.items()),repo
 stashes=git(repo,'stash','list').splitlines()
 trees=[line for line in git(repo,'worktree','list','--porcelain').splitlines() if line.startswith('worktree ')]
 uncovered=git(repo,'rev-list','--reflog','--not','--remotes=origin','--tags').splitlines()
 assert not stashes and len(trees)==1 and not uncovered,(repo,stashes,trees,uncovered)
 result.append(dict(repo=repo.name,head=head,remote_main=remote,dirty_entries=0,local_branches=local,
 remote_heads=sorted(heads),worktrees=len(trees),stashes=0,uncovered_reflog_commits=0,remote_verified_tags=len(local_tags)))
report=dict(scope='repository source state only',verified_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
 repository_count=len(result),all_current_main=True,repositories=result)
assert len(result)==12
path=Path(__file__).resolve().parent/'repositories-current-main.json'
path.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
