"""Check actual model download bodies with bounded traffic; never installs files.

By default the probe connects directly, ignoring environment proxies. Use
--system-proxy to compare the host's environment proxy route. A successful check
on this host is not a guarantee for every ISP or region.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--system-proxy', action='store_true')
    parser.add_argument('--sources', nargs='+', default=['mainland', 'mirror_proxy', 'mirror'])
    parser.add_argument('--output', default='.artifacts/model-center/sources-check.json')
    parser.add_argument('--catalog', default='assets/models/catalog.json')
    args = parser.parse_args()
    catalog = json.loads(Path(args.catalog).read_text(encoding='utf-8'))
    jobs = [(model['id'], file, key, url)
            for model in catalog.get('models', catalog.get('components', [])) for file in model['files']
            for key, url in file['sources'].items() if key in args.sources]

    def probe(job):
        model, file, key, url = job
        result = dict(model=model, file=file['name'], source=key, url=url)
        start = time.monotonic()
        try:
            opener = urllib.request.build_opener() if args.system_proxy else urllib.request.build_opener(urllib.request.ProxyHandler({}))
            size = min(65536, file['bytes'])
            request = urllib.request.Request(url, headers={
                'Range': f'bytes=0-{size - 1}', 'Accept-Encoding': 'identity',
                'User-Agent': 'FluentPlayer-model-source-check/1',
            })
            with opener.open(request, timeout=15) as response:
                data = response.read(size)
                result.update(status=response.status, finalHost=urllib.parse.urlparse(response.url).hostname,
                              received=len(data), contentRange=response.headers.get('Content-Range'))
                assert response.status in [200, 206]
                assert 'text/html' not in response.headers.get('Content-Type', '')
                assert len(data) == size, 'incomplete sample'
                if response.status == 206:
                    match = re.fullmatch(r'bytes 0-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                    assert match and int(match[2]) == file['bytes'], 'wrong file range/size'
                if size == file['bytes']:
                    assert hashlib.sha256(data).hexdigest() == file['sha256'], 'SHA-256 mismatch'
                    result['fullHashVerified'] = True
                result['ok'] = True
        except Exception as error:
            result.update(ok=False, error=str(error))
        result['seconds'] = round(time.monotonic() - start, 3)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        results = list(pool.map(probe, jobs))
    target = Path(args.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(dict(route='environment' if args.system_proxy else 'direct',
                                     results=results), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    passed = sum(result['ok'] for result in results)
    print(f'{passed}/{len(results)} source samples passed: {target}')
    for result in results:
        if not result['ok']:
            print(f'{result["model"]}/{result["file"]} [{result["source"]}]: {result["error"]}')


if __name__ == '__main__':
    main()
