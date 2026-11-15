#!/usr/bin/env python3
"""Register only this user's explicitly installed SSH Observatory helper."""
from pathlib import Path
import argparse,os,plistlib,subprocess,tempfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--app',type=Path,default=Path('/Applications/SSH Observatory.app'))
p.add_argument('--stop',action='store_true',help='Unload this service; retain its configuration')
a=p.parse_args();app=a.app.resolve()
label='org.sshobservatory.security-contour';target=f'gui/{os.getuid()}/{label}'
helper=app/'Contents/Library/LoginItems/SSH Security Contour.app/Contents/MacOS/SecurityContour'
plist=Path.home()/'Library/LaunchAgents'/f'{label}.plist'
if a.stop:
 subprocess.run(['/bin/launchctl','bootout',target],check=True);raise SystemExit(0)
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier')!='org.sshobservatory.app' or not helper.is_file():p.error('Choose the built SSH Observatory application')
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
value={'Label':label,'ProgramArguments':[str(helper),'--security-contour'],'RunAtLoad':False,'KeepAlive':{'Crashed':True},'ThrottleInterval':10,'ProcessType':'Background','StandardOutPath':'/dev/null','StandardErrorPath':'/dev/null'}
plist.parent.mkdir(parents=True,exist_ok=True)
if plist.is_symlink():p.error('Refusing a symlink launch agent')
if plist.exists() and plistlib.loads(plist.read_bytes())!=value:p.error('Existing service configuration differs; inspect it before updating')
if not plist.exists():
 fd,temp=tempfile.mkstemp(prefix='.ssh-observatory-',dir=plist.parent)
 try:
  os.fchmod(fd,0o600)
  with os.fdopen(fd,'wb') as f:f.write(plistlib.dumps(value))
  os.link(temp,plist)
 finally:os.unlink(temp)
loaded=subprocess.run(['/bin/launchctl','print',target],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
if not loaded:subprocess.run(['/bin/launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)],check=True)
subprocess.run(['/bin/launchctl','kickstart',target],check=True)
print('Protected service registered for this user. Login startup is disabled.')
