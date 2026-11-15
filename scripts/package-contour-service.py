"""Package the shared executable with a distinct background bundle identity."""
from pathlib import Path
import plistlib,shutil,subprocess,sys
app=Path(sys.argv[1]).resolve()
helper=app/'Contents/Library/LoginItems/SSH Security Contour.app'
c=helper/'Contents'
(c/'MacOS').mkdir(parents=True,exist_ok=True)
(c/'Frameworks').mkdir(exist_ok=True)
shutil.copy2(app/'Contents/MacOS/SSHObservatory',c/'MacOS/SecurityContour')
shutil.copy2(app/'Contents/Frameworks/libTelemetryCore.dylib',c/'Frameworks/libTelemetryCore.dylib')
shutil.copytree(app/'Contents/Resources',c/'Resources',dirs_exist_ok=True)
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
for key in ['CFBundleIconFile']:info.pop(key,None)
info.update(CFBundleExecutable='SecurityContour',CFBundleIdentifier='org.sshobservatory.security-contour',CFBundleName='SSH Security Contour',CFBundleDisplayName='Security Contour — VPN → Tor → SSH',LSBackgroundOnly=True)
(c/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(c/'Frameworks/libTelemetryCore.dylib')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(helper)],check=True)
