"""Build a test-only Android APK targeting the installed diagnostic application.
No app data is cleared. This APK is never part of a release build.
"""
import os
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
SDK=Path(os.environ.get('ANDROID_HOME',Path(os.environ['LOCALAPPDATA'])/'Android/sdk'))
BUILD=SDK/'build-tools/36.0.0'
JAVA=Path('D:/Android Studio/jbr/bin')
ANDROID=SDK/'platforms/android-36/android.jar'
FLUTTER=Path('D:/FlutterSDK/flutter/bin/cache/artifacts/engine/android-arm64/flutter.jar')
WORK=ROOT/'.artifacts/qwen-android-fix-20261031/probe'

def run(args,**kwargs):
    env=dict(os.environ)
    env['JAVA_HOME']=str(JAVA.parent)
    subprocess.run([str(a) for a in args],check=True,env=env,**kwargs)

def main():
    classes=WORK/'classes';dex=WORK/'dex'
    classes.mkdir(parents=True,exist_ok=True);dex.mkdir(parents=True,exist_ok=True)
    run([JAVA/'javac.exe','-source','17','-target','17','-classpath',str(ANDROID)+';'+str(FLUTTER),'-d',classes,
        ROOT/'tool/android_qwen_probe/NativeProbe.java'])
    run([BUILD/'d8.bat','--min-api','24','--lib',ANDROID,'--lib',FLUTTER,'--output',dex,*classes.rglob('*.class')])
    unsigned=WORK/'unsigned.apk';apk=WORK/'qwen-native-probe.apk'
    run([BUILD/'aapt.exe','package','-f','-M',ROOT/'tool/android_qwen_probe/AndroidManifest.xml','-I',ANDROID,'-F',unsigned])
    run([BUILD/'aapt.exe','add',unsigned,'classes.dex'],cwd=dex)
    run([BUILD/'apksigner.bat','sign','--ks',Path(os.environ['USERPROFILE'])/'.android/debug.keystore',
        '--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',apk,unsigned])
    print(apk)
if __name__=='__main__':main()
