"""One controlled CPU request for the private timeout-callback diagnostic."""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import time

from run_android_resource_audit import AUDIT, PACKAGE, adb, request, save


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--expect-diagnostic-error", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9-]+", args.tag):
        raise SystemExit("Unsafe evidence tag")
    path = AUDIT / (args.tag + "-timeout.json")
    if path.exists():
        raise SystemExit("Refusing to overwrite native evidence")
    initial = request('/status')
    external = initial['native']['externalFiles']
    if not external.endswith('/Android/data/' + PACKAGE + '/files'):
        raise SystemExit('Wrong private package')
    mem = adb('shell', 'cat', '/proc/meminfo')
    available = int(re.search(r'(?m)^MemAvailable:\s+(\d+)', mem).group(1)) * 1024
    needed = 1882037824 * 2 + 256 * 1024 * 1024
    if available < needed:
        raise SystemExit(f'Existing admission declined CPU diagnostic: {available} < {needed}')
    owner = 'resource-audit-timeout-probe'
    report = {'tag': args.tag, 'availableBytes': available, 'neededBytes': needed, 'records': []}

    def call(body, method='request'):
        value = request('/bridge?kind=qwen&method=' + method, body)
        report['records'].append({'request': body, 'method': method, 'response': value})
        save(path, report)
        return value

    load = {'op': 'load', 'owner': owner, 'kind': 'asr', 'model': external + '/resource-audit/models/qwen.gguf',
            'threads': 2, 'backend': 'cpu', 'language': 'zh'}
    try:
        call({'op': 'open', 'owner': owner})
        loaded = call(load)
        if loaded['result'].get('ok') is not True:
            raise RuntimeError(loaded)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(call, {'op': 'decode', 'owner': owner, 'path': external + '/resource-audit/speech.f32'})
            time.sleep(.15)
            report['beforeFire'] = request('/status')
            if report['beforeFire']['native']['qwenPending'] != 1:
                raise RuntimeError('No single actual native request was pending at injection')
            try:
                report['fireResponse'] = request('/fire-timeout?label=QwenAsrBridge.kt')
            except Exception as error:
                report['fireError'] = repr(error)
            save(path, report)
            report['decode'] = pending.result(timeout=90)
        call({'owner': owner}, 'close')
        if args.expect_diagnostic_error:
            report['reproducedDiagnosticError'] = 'fireError' in report and 'httpStatus' in report['fireError']
            report['passed'] = report['reproducedDiagnosticError']
        else:
            if report.get('fireError') or not report.get('fireResponse', {}).get('result', {}).get('fired'):
                raise RuntimeError('Did not fire the actual live callback')
            if report['decode']['result'].get('ok') is not False:
                raise RuntimeError('Live request did not complete with timeout/cancellation')
            time.sleep(2)
            current_mem = adb('shell', 'cat', '/proc/meminfo')
            reopened_available = int(re.search(r'(?m)^MemAvailable:\s+(\d+)', current_mem).group(1)) * 1024
            report['reopenAdmission'] = {'availableBytes': reopened_available, 'neededBytes': needed}
            if reopened_available < needed:
                raise RuntimeError('Existing admission declined timeout recovery load')
            call({'op': 'open', 'owner': owner})
            call(load)
            reopened = call({'op': 'decode', 'owner': owner, 'path': external + '/resource-audit/speech.f32'})
            payload = reopened['result'].get('result', reopened['result'])
            if not payload.get('text'):
                raise RuntimeError('CPU model failed after timeout recovery')
            report['reopenedText'] = payload['text']
            call({'owner': owner}, 'close')
            report['passed'] = True
    finally:
        call({'owner': owner}, 'close')
        report['final'] = request('/status')
        save(path, report)
    print(json.dumps(report, ensure_ascii=True)[-3000:])


if __name__ == '__main__':
    main()
