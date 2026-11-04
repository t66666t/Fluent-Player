"""Create a local community-only release key once; never overwrite an existing key."""
import argparse
import os
from pathlib import Path
import secrets
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keytool', default=shutil.which('keytool'))
    args = parser.parse_args()
    if not args.keytool:
        parser.error('Pass --keytool <JDK/bin/keytool.exe>')
    directory = ROOT / '.artifacts/community-signing'
    directory.mkdir(parents=True, exist_ok=True)
    properties = directory / 'key.properties'
    key = directory / 'community-release.jks'
    if properties.exists() and key.exists():
        print('Existing community release signing preserved.')
        return
    if properties.exists() or key.exists():
        raise SystemExit('Incomplete signing setup; restore the matching backup before continuing.')
    password = secrets.token_urlsafe(36)
    environment = dict(os.environ, FLUENT_COMMUNITY_KEY_PASSWORD=password)
    subprocess.run([
        args.keytool, '-genkeypair', '-noprompt', '-keystore', str(key),
        '-storetype', 'JKS', '-alias', 'community-release', '-keyalg', 'RSA',
        '-keysize', '3072', '-validity', '10000',
        '-dname', 'CN=Fluent Player Community, O=Community, C=CN',
        '-storepass:env', 'FLUENT_COMMUNITY_KEY_PASSWORD',
        '-keypass:env', 'FLUENT_COMMUNITY_KEY_PASSWORD',
    ], env=environment, check=True)
    properties.write_text(
        f'storeFile={key.as_posix()}\nstorePassword={password}\n'
        f'keyAlias=community-release\nkeyPassword={password}\n', encoding='utf-8')
    print('Community release signing created under .artifacts/community-signing; back up this directory securely.')


if __name__ == '__main__':
    main()
