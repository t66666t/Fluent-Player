"""Check two explicit, independently maintained checkouts for edition collisions.

Read-only; never edits settings, contacts services, or adopts the other edition's data.
Usage: python tool/verify_edition_isolation.py --other-project <other-checkout>
"""
import argparse
import json
from pathlib import Path
import re


def identity(root):
    def text(path):
        return (root / path).read_text(encoding='utf-8')
    branding = text('lib/utils/app_branding.dart')
    def value(key):
        match = re.search(r'const ' + key + r" = ('([^']*)'|[0-9]+|true|false);", branding)
        if match is None:
            raise ValueError('Missing explicit branding constant: ' + key)
        return match[2] if match[2] is not None else match[1]
    windows = text('windows/runner/Runner.rc')
    installer = text('packaging/windows/fluent-player.iss')
    appid = value('kApplicationId')
    linux = text('lib/platform/linux_application_identity.dart')
    legacy_block = re.search(r'linuxLegacyApplicationIds\s*=\s*(?:<String>)?\[(.*?)\];', linux, re.S)
    legacy = re.findall(r"'([^']+)'", legacy_block[1]) if legacy_block else []
    return {
        'applicationId': appid,
        'displayName': value('kAppDisplayName'),
        'community': value('kIsCommunityEdition') == 'true',
        'mcpName': value('kMcpServerName'),
        'mcpPort': int(value('kExternalAiDefaultPort')),
        'syncPort': int(value('kProgressSyncDefaultPort')),
        'discoveryPort': int(value('kProgressSyncDiscoveryPort')),
        'discoveryTargets': [int(port) for port in re.findall(
            r'[0-9]+', re.search(r'kProgressSyncDiscoveryTargets\s*=\s*<int>\[(.*?)\];', branding, re.S)[1])],
        'windowsSupport': tuple(re.search(r'VALUE "' + key + r'", "([^"]+)"', windows)[1]
                                for key in ('CompanyName', 'ProductName')),
        'installerGuid': re.search(r'^AppId=(.+)$', installer, re.M)[1],
        'installDirectory': re.search(r'^DefaultDirName=(.+)$', installer, re.M)[1],
        'legacyLinux': legacy,
    }


def verify(first, second):
    records = [identity(first), identity(second)]
    if records[0]['community'] == records[1]['community']:
        raise ValueError('Provide one standard checkout and one Pro checkout')
    for field in ('applicationId', 'displayName', 'mcpName', 'mcpPort', 'syncPort',
                  'discoveryPort', 'windowsSupport', 'installerGuid', 'installDirectory'):
        if records[0][field] == records[1][field]:
            raise ValueError('Cross-edition collision: ' + field)
    pro = next(r for r in records if not r['community'])
    standard = next(r for r in records if r['community'])
    assert pro['applicationId'] == 'cn.teezy.fluentplayer.pro'
    assert standard['applicationId'] == 'cn.teezy.fluentplayer.standard'
    if 'cn.teezy.fluentplayer' in standard['legacyLinux']:
        raise ValueError('Standard must never adopt the old full-edition data root')
    if set(pro['legacyLinux']) & set(standard['legacyLinux']):
        raise ValueError('Both editions adopt the same historical Linux data')
    for record in records:
        if record['discoveryTargets'] != [record['discoveryPort']]:
            raise ValueError('Discovery must target only the same edition')
    ports = [r[field] for r in records for field in ('mcpPort', 'syncPort', 'discoveryPort')]
    if len(set(ports)) != len(ports):
        raise ValueError('A default service port is shared by two services')
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--other-project', required=True, type=Path)
    args = parser.parse_args()
    result = verify(Path(__file__).resolve().parents[1], args.other_project.resolve(strict=True))
    print(json.dumps({'editionIsolation': 'passed', 'editions': result}, ensure_ascii=False, indent=2))
