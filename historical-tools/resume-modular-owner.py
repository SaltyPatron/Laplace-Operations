from pathlib import Path
import subprocess,json,pwd,os,tempfile
root=Path("/repos/work/agents/Laplace-Operations/Laplace-Operations/Laplace-Operations")
names=["Laplace-Native","Laplace-Engine","Laplace-postgres","Laplace-MCP","Laplace-Operations"]
expected={"Laplace-Native":"140273083f149358b2c8f3cce3e69c781df889b2","Laplace-Engine":"03f616b8880e3bf0b817a8f872411e411f1b65d3","Laplace-postgres":"acc33f25101bb2df491ea635aaf5cafdae6e128a","Laplace-MCP":"b4bd89be403523b5c6a45fda4c4d5b97c8dfe006","Laplace-Operations":"14f24c9267863ff53569b2748bb144b8717f23d9"}
env=dict(os.environ)
for i,name in enumerate(names):
 p=root/name
 if pwd.getpwuid(p.stat().st_uid).pw_name != "laplace-runner":raise RuntimeError("Unexpected source owner")
 def git(*args):return subprocess.run(["git","-c","safe.directory="+str(p),"-C",str(p),*args],capture_output=True,text=True,check=True).stdout.strip()
 if git("rev-parse","HEAD") != expected[name] or git("status","--porcelain","--untracked-files=no"):
  raise RuntimeError("Source revision changed; activation source must be reviewed: "+name)
 for j,value in enumerate((str(p),str(p/".git"))):
  index=2*i+j
  env["GIT_CONFIG_KEY_"+str(index)]="safe.directory"
  env["GIT_CONFIG_VALUE_"+str(index)]=value
env["GIT_CONFIG_COUNT"]=str(2*len(names))
env["LAPLACE_SRC"]=str(root)
env["LAPLACE_HOST_LOCK_WAIT_SECONDS"]="wait"
print(json.dumps({"host":"hart-server","operation":"resume modular owner activation","source_revisions":expected}),flush=True)
with tempfile.TemporaryDirectory(prefix="laplace-owner-git-") as temporary:
 config=Path(temporary)/"gitconfig"
 for name in names:
  for value in (root/name,root/name/".git"):
   subprocess.run(["git","config","--file",str(config),"--add","safe.directory",str(value)],check=True)
 env["GIT_CONFIG_GLOBAL"]=str(config)
 raise SystemExit(subprocess.run(["python3",str(root/"Laplace-Operations/installation/modular.py"),"deploy","--source",str(root)],env=env).returncode)
