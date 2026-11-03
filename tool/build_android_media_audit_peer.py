"""Build a silent, isolated Android media-control peer with SDK tools only.

Never installs, launches, connects to, or otherwise operates any Android device.
No Flutter/Gradle, production signing material, account or application data is read.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tool/android_media_audit_peer'
PACKAGE = 'com.fluentplayer.audit.controls'
TARGET = 'com.example.video_player_app.sidebar_profile/com.ryanheise.audioservice.MediaButtonReceiver'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not default_sdk:
        default_sdk = str(Path(os.environ.get('LOCALAPPDATA', str(Path.home() / 'AppData/Local'))) / 'Android/sdk')
    parser.add_argument('--sdk', type=Path, default=Path(default_sdk))
    parser.add_argument('--java-home', type=Path, default=Path('D:/Android Studio/jbr'))
    parser.add_argument('--build-tools', default='36.0.0')
    parser.add_argument('--output', type=Path,
                        default=ROOT / 'build/android-release-audit-20261031/evidence/media-control-peer')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    work = output / ('build-' + stamp + '-' + uuid.uuid4().hex[:8])
    work.mkdir()
    tools = args.sdk / 'build-tools' / args.build_tools
    android = args.sdk / 'platforms/android-36/android.jar'
    java = args.java_home / 'bin'
    executable = '.exe' if os.name == 'nt' else ''
    batch = '.bat' if os.name == 'nt' else ''
    required = [android, java / ('javac' + executable), java / ('java' + executable),
                java / ('keytool' + executable), tools / ('d8' + batch),
                tools / ('aapt2' + executable), tools / ('zipalign' + executable), tools / ('apksigner' + batch)]
    for path in required:
        if not path.is_file():
            parser.error(f'Missing SDK/JDK input: {path}')
    env = dict(os.environ, JAVA_HOME=str(args.java_home))
    env['PATH'] = str(java) + os.pathsep + env.get('PATH', '')
    commands = []

    def run(label, command):
        command = [str(value) for value in command]
        commands.append({'label': label, 'command': command})
        result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding='utf8', errors='replace')
        log = work / (label + '.log')
        log.write_text(result.stdout, encoding='utf8')
        if result.returncode:
            raise RuntimeError(f'{label} failed ({result.returncode}); see {log}\n{result.stdout[-4000:]}')
        return result.stdout

    classes = work / 'classes'; classes.mkdir()
    policy_classes = work / 'policy-check-classes'; policy_classes.mkdir()
    dex = work / 'dex'; dex.mkdir()
    javac = [java / ('javac' + executable), '-J-Duser.language=en', '-J-Duser.country=US',
             '-encoding', 'UTF-8', '--release', '17', '-classpath', android]
    run('policy-javac', javac + ['-d', policy_classes, SOURCE / 'AuditPolicy.java',
                                SOURCE / 'test/AuditPolicyTest.java'])
    policy_result = run('policy-check', [java / ('java' + executable), '-cp', policy_classes,
                                        PACKAGE + '.AuditPolicyTest'])
    run('notification-policy-javac', javac + ['-d', policy_classes, SOURCE / 'NotificationExpandPolicy.java',
                                             SOURCE / 'test/NotificationExpandPolicyTest.java'])
    notification_policy_result = run('notification-policy-check', [java / ('java' + executable), '-cp', policy_classes,
                                                                  PACKAGE + '.NotificationExpandPolicyTest'])
    run('notification-diagnostics-javac', javac + ['-d', policy_classes, SOURCE / 'NotificationExpandDiagnostics.java',
                                                  SOURCE / 'test/NotificationExpandDiagnosticsTest.java'])
    notification_diagnostics_result = run('notification-diagnostics-check', [java / ('java' + executable), '-cp', policy_classes,
                                                                           PACKAGE + '.NotificationExpandDiagnosticsTest'])
    run('notification-title-search-javac', javac + ['-d', policy_classes, SOURCE / 'NotificationExpandPolicy.java',
                                                    SOURCE / 'NotificationTitleSearch.java', SOURCE / 'test/NotificationTitleSearchTest.java'])
    notification_title_search_result = run('notification-title-search-check', [java / ('java' + executable), '-cp', policy_classes,
                                                                             PACKAGE + '.NotificationTitleSearchTest'])
    run('javac', javac + ['-d', classes, *sorted(SOURCE.glob('*.java'))])
    run('d8', [tools / ('d8' + batch), '--min-api', '24', '--lib', android,
               '--output', dex, *sorted(classes.rglob('*.class'))])
    resources = work / 'resources.apk'
    run('aapt2-link', [tools / ('aapt2' + executable), 'link', '-o', resources,
                       '--manifest', SOURCE / 'AndroidManifest.xml', '-I', android,
                       '--min-sdk-version', '24', '--target-sdk-version', '36',
                       '--version-code', '1', '--version-name', '0.1-test'])
    unsigned = work / 'unsigned.apk'
    shutil.copy2(resources, unsigned)
    with zipfile.ZipFile(unsigned, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(dex.glob('*.dex')):
            archive.write(path, path.name)
    aligned = work / 'aligned.apk'
    run('zipalign', [tools / ('zipalign' + executable), '-f', '4', unsigned, aligned])
    # A generated fixture identity; never reads key.properties or a production key.
    key = output / 'peer-debug.keystore'
    if not key.exists():
        run('debug-key', [java / ('keytool' + executable), '-genkeypair', '-keystore', key,
                           '-storepass', 'android', '-keypass', 'android', '-alias', 'androiddebugkey',
                           '-dname', 'CN=Android Debug,O=Android,C=US', '-keyalg', 'RSA',
                           '-keysize', '2048', '-validity', '3650', '-noprompt'])
    apk = output / 'fluent-media-audit-peer.apk'
    run('sign', [tools / ('apksigner' + batch), 'sign', '--ks', key, '--ks-key-alias', 'androiddebugkey',
                 '--ks-pass', 'pass:android', '--key-pass', 'pass:android', '--out', apk, aligned])
    certificate = run('verify-signature', [tools / ('apksigner' + batch), 'verify', '--verbose', '--print-certs', apk])
    badging = run('verify-badging', [tools / ('aapt2' + executable), 'dump', 'badging', apk])
    manifest = run('verify-manifest', [tools / ('aapt2' + executable), 'dump', 'xmltree', apk,
                                      '--file', 'AndroidManifest.xml'])
    run('verify-zipalign', [tools / ('zipalign' + executable), '-c', '4', apk])
    if (f"package: name='{PACKAGE}'" not in badging or "targetSdkVersion:'36'" not in badging
            or not re.search(r"(?:minSdkVersion|sdkVersion):'24'", badging)):
        raise ValueError('Unexpected peer APK identity/SDK')
    if 'application-debuggable' not in badging or 'CN=Android Debug' not in certificate:
        raise ValueError('Peer must remain debuggable and debug-signed')
    if 'testOnly' not in manifest or 'uses-permission' in manifest or 'android.permission.INTERNET' in manifest:
        raise ValueError('Peer must remain testOnly and request no permissions/network access')
    if manifest.count('E: activity ') != 2 or 'E: service ' in manifest or 'E: receiver ' in manifest:
        raise ValueError('Peer must expose only its two audit activities, without services or receivers')
    instrumentation_blocks = manifest.split('E: instrumentation ')[1:]
    if len(instrumentation_blocks) != 3:
        raise ValueError('Peer must contain exactly its UI-dump, text-input and known-notification-expansion instrumentations')
    instrumentation_names = set()
    attribute = r'A: (?:android|http://schemas.android.com/apk/res/android):'
    for instrumentation in instrumentation_blocks:
        targets = re.findall(attribute + r'targetPackage[^=\n]*="([^"]+)"', instrumentation)
        names = re.findall(attribute + r'name[^=\n]*="([^"]+)"', instrumentation)
        if targets != [PACKAGE] or len(names) != 1:
            raise ValueError('Every instrumentation must target the helper itself, never any player package')
        instrumentation_names.add(names[0].rsplit('.', 1)[-1])
    if instrumentation_names != {'UiDumpInstrumentation', 'TextInputInstrumentation', 'ExpandModelNotificationInstrumentation'}:
        raise ValueError('Unexpected instrumentation classes')
    fingerprints = re.findall(r'certificate SHA-256 digest:\s*([0-9a-fA-F]+)', certificate)
    if not fingerprints:
        raise ValueError('No verified public signing-certificate fingerprint')
    result = {
        'status': 'built-and-verified-not-installed', 'builtUtc': stamp,
        'apk': str(apk), 'apkBytes': apk.stat().st_size, 'apkSha256': sha(apk),
        'package': PACKAGE, 'minSdk': 24, 'targetSdk': 36, 'debuggable': True, 'testOnly': True,
        'permissions': [], 'networkAccess': False, 'productionKeyRead': False, 'deviceOperations': 0,
        'certificateSha256': sorted(set(value.lower() for value in fingerprints)),
        'strictMediaButtonTarget': TARGET,
        'mediaButtonActivity': PACKAGE + '.AuditMediaButtonActivity',
        'focusActivity': PACKAGE + '.AuditFocusActivity',
        'uiDumpInstrumentation': PACKAGE + '.UiDumpInstrumentation',
        'instrumentationTargetPackage': PACKAGE,
        'uiDumpPrivatePath': 'files/ui/latest.xml',
        'uiDumpWaitForIdle': False, 'uiDumpInputInjection': False, 'uiDumpAppLaunch': False,
        'uiDumpCustomFilename': 'ASCII alphanumeric basename (1-64 chars) plus .xml only',
        'textInputInstrumentation': PACKAGE + '.TextInputInstrumentation',
        'textInputIsExplicitWriteEntryPoint': True,
        'textInputRequiredForegroundRootPackage': 'com.example.video_player_app.sidebar_profile',
        'textInputRequiredClass': 'android.widget.EditText',
        'textInputRequiresUniqueEditable': True, 'textInputMaxUtf8Bytes': 64 * 1024,
        'textInputAction': 'ACTION_SET_TEXT only; no click/focus/selection/global keys/clipboard/app launch',
        'textInputAcceptedActionPropagationHoldMs': 500,
        'textInputResultMeaning': 'Accessibility provider acceptance only; rendered/application value and business outcome are not verified.',
        'expandModelNotificationInstrumentation': PACKAGE + '.ExpandModelNotificationInstrumentation',
        'expandModelNotificationTargetRoot': 'com.android.systemui',
        'expandModelNotificationExactTitle': 'Fluent Player 模型中心',
        'expandModelNotificationPolicy': 'Bounded complete tree traversal compares SystemUI title fields in RAM, retaining only the unique exact known-title node and numeric counters; no other title/body/description text is saved. Explicit single row or direct notification-stack child; one title field/content container, no nested rows; stable fresh repeated snapshots. ACTION_EXPAND if advertised, otherwise one two-finger drag with both DOWN points inside row, distance <=360px (<500), all points inside active SystemUI window. No click, service command or retry.',
        'expandModelNotificationInspectOnlyArgument': '-e inspect_only true',
        'expandModelNotificationPolicyCheck': notification_policy_result.strip(),
        'expandModelNotificationDiagnosticsCheck': notification_diagnostics_result.strip(),
        'expandModelNotificationTitleSearchCheck': notification_title_search_result.strip(),
        'expandModelNotificationDiagnostics': 'Fixed enum stage/reasonCode plus fixed-key numeric counters; no framework exception messages or unrelated notification text. The UI policy/action boundaries are unchanged.',
        'mediaCommands': ['play', 'pause', 'next', 'previous', 'play_pause'],
        'mediaCommandSemantics': 'Raw Android key codes. audio_service 0.18.19 intentionally maps PLAY and PAUSE to media-button toggle; these do not prove idempotent explicit play/pause.',
        'focusModes': ['transient', 'gain'], 'defaultHoldSeconds': 5, 'maxHoldSeconds': 30,
        'receiptDirectory': 'files/media-audit-peer/receipts', 'maxReceipts': 128,
        'policyCheck': policy_result.strip(), 'work': str(work), 'commands': commands,
        'sourceHashes': {str(path.relative_to(ROOT)).replace('\\', '/'): sha(path)
                         for path in [*sorted(SOURCE.rglob('*')), Path(__file__)] if path.is_file()},
        'limitations': [
            'Explicit MEDIA_BUTTON dispatch is not physical-headset/AVRCP/session-routing/noisy-event validation.',
            'A send receipt does not acknowledge target receipt, intent application or audible playback.',
            'Raw PLAY and PAUSE are both media-button toggles in the current Android audio_service; not an idempotence test.',
            'The silent foreground focus peer tests focus callbacks, not phone calls, audio routing, ducking/fade audibility or screen-off endurance.',
            'Launching this peer changes the foreground Activity; record target/FGS state separately.',
            'An actual audio-focus request participates in the system focus stack and is not target-addressable.',
            'UI snapshots do not wait for idle and may be transient/truncated; framework Binder calls themselves cannot be preempted by the traversal budget.',
            'am instrument targets only this helper and may recreate its own process; do not run it while the same helper is intentionally holding focus.',
            'TextInputInstrumentation is a separate explicitly authorized write action, restricted to one editable EditText in the exact foreground profile package. A true action result acknowledges accessibility acceptance, not business/form validation.',
            'An accepted text action keeps UiAutomation connected for 500ms without waitForIdle or retries; this is a propagation opportunity, not proof that Flutter or the eventual operation adopted the text. Check screenshot and actual output separately.',
            'Notification expansion is a separate explicit SystemUI UI-write entry point. It requires the already open shade and stable known single card, never launches the shade/app, never clicks Pause, and never sends a model-service command. A gesture may extend below the original compact row after both pointers start inside it; it remains within the active SystemUI window and strictly below 500px. Acceptance/injection is not proof of expansion or interruption; root must verify actual UI and click the visible own action separately.',
            'Notification geometry/selection is covered by host policy checks, not actual SystemUI delivery. Partial gestures attempt ACTION_CANCEL; actual cancellation acceptance is not verified. Individual framework Binder calls cannot be preempted by freshness/gesture deadlines. Third-party exception messages and other notification texts/descriptions are not saved.',
            'SDK build, local policy execution and APK identity/signature checks only; device validation belongs to root.'
        ],
    }
    receipt = output / 'media-control-peer-build-result.json'
    receipt.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf8')
    print(json.dumps({name: result[name] for name in ['status', 'apk', 'apkSha256', 'apkBytes',
                                                     'strictMediaButtonTarget', 'policyCheck']}, indent=2))


if __name__ == '__main__':
    main()
