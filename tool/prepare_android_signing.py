"""Materialize CI signing inputs without printing credentials or replacing local keys."""
import base64
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def property_value(value):
    value = (value.replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r')
             .replace('\t', '\\t').replace(' ', '\\ ').replace('=', '\\=').replace(':', '\\:'))
    encoded = value.encode('utf-16-be')
    units = [int.from_bytes(encoded[index:index + 2], 'big') for index in range(0, len(encoded), 2)]
    return ''.join(chr(unit) if unit < 128 else f'\\u{unit:04x}' for unit in units)


def main():
    names = ('ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD',
             'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD', 'RUNNER_TEMP')
    if any(not os.environ.get(name) for name in names):
        raise ValueError('Configure the original Android signing secrets before building a release')
    properties = ROOT / 'android/key.properties'
    keystore = Path(os.environ['RUNNER_TEMP']) / 'fluent-player-release.keystore'
    if properties.exists() or keystore.exists():
        raise ValueError('Refusing to overwrite existing Android signing files')
    data = base64.b64decode(os.environ['ANDROID_KEYSTORE_BASE64'], validate=True)
    if not data:
        raise ValueError('Empty Android signing keystore')
    os.umask(0o077)
    with keystore.open('xb') as sink:
        sink.write(data)
    values = {'storeFile': keystore.resolve().as_posix(),
              'storePassword': os.environ['ANDROID_KEYSTORE_PASSWORD'],
              'keyAlias': os.environ['ANDROID_KEY_ALIAS'],
              'keyPassword': os.environ['ANDROID_KEY_PASSWORD']}
    try:
        with properties.open('x', encoding='ascii') as sink:
            for key, value in values.items():
                sink.write(f'{key}={property_value(value)}\n')
    except Exception:
        keystore.unlink()
        raise


if __name__ == '__main__':
    main()
