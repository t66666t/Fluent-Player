"""Build the OCR catalog from pinned official HF and ModelScope revisions.

Downloads metadata/configuration only. Weight hashes must match on both hosts;
configuration bodies are checked too. Never repoints ASR/translation revisions.
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request
import time

REVISIONS = {
    'PP-OCRv6_tiny_det_onnx': '2ba1506c0380b8f0b03dd142459aac66d4421f6c',
    'PP-OCRv6_small_det_onnx': '28fe5895c24fd108c19eb3e8479f4ab385fbfc62',
    'PP-OCRv6_small_rec_onnx': 'b8f84f0b80c529de40b4fbb3544b84fa7233a513',
    'PP-OCRv6_medium_det_onnx': '61323801669c338b7891481ec7bac61ce31b576a',
    'PP-OCRv6_medium_rec_onnx': '50c7eacafc52fa7bcf4194e8cd08e46f8558504b',
    'PP-OCRv5_mobile_det_onnx': 'e6f4fa85f00e168c862bc462aebca69eef9b3d3d',
    'PP-OCRv5_mobile_rec_onnx': 'ed152b8b495f84de93cda5709d768548a9127622',
    'en_PP-OCRv5_mobile_rec_onnx': '3fafbc3b5dcf93dd72add9f48368be8a3a2cd33b',
    'korean_PP-OCRv5_mobile_rec_onnx': '5c6f574b8e2230adf4287b33e736d71b9fabd28e',
    'latin_PP-OCRv5_mobile_rec_onnx': '89d3a50e2c27e2e7cceeab0e944c25c807d5db4f',
}
LATIN = ['af','az','bs','ca','cs','cy','da','de','es','et','eu','fi','fr','ga',
         'gl','hr','hu','id','is','it','ku','la','lb','lt','lv','mi','ms','mt',
         'nl','no','oc','pi','pl','pt','qu','rm','ro','sk','sl','sq','sv','sw',
         'tl','tr','uz','vi']


def read(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'FluentPlayer-OCR-catalog/1'})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return response.read()
        except Exception:
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def component_id(name):
    return 'ocr-' + name.replace('PP-OCR', '').replace('_onnx', '').replace('_', '-').lower()


def resolve(item):
    name, revision = item
    repo = f'PaddlePaddle/{name}'
    hf = json.loads(read(f'https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true'))
    ms = json.loads(read(f'https://modelscope.cn/api/v1/models/{repo}/repo/files?Revision=master&Recursive=true'))
    ms_files = {entry['Path']: entry for entry in ms['Data']['Files']}
    files = []
    for entry in hf['siblings']:
        filename = entry['rfilename']
        if filename not in ['inference.onnx', 'inference.yml']:
            continue
        url = f'https://huggingface.co/{repo}/resolve/{revision}/{filename}'
        digest = entry.get('lfs', {}).get('sha256')
        if not digest:
            digest = hashlib.sha256(read(url)).hexdigest()
        remote = ms_files[filename]
        assert entry['size'] == remote['Size'] and digest == remote['Sha256'], (repo, filename)
        domestic = f'https://modelscope.cn/models/{repo}/resolve/{remote["Revision"]}/{filename}'
        if filename.endswith('.yml'):
            assert hashlib.sha256(read(domestic)).hexdigest() == digest
        files.append(dict(name=filename, bytes=entry['size'], sha256=digest, sources={
            'official': url, 'mainland': domestic,
            'mirror': url.replace('https://huggingface.co/', 'https://hf-mirror.com/'),
            'mirror_proxy': url.replace('https://huggingface.co/', 'https://hf-mirror.net/'),
        }))
    assert len(files) == 2, repo
    return dict(id=component_id(name), name=name.replace('_onnx', ''),
                engine='ppocr', revision=revision, parameters='上游未单列组件参数量',
                quantization='FP32 · ONNX', languages=[], description='OCR 共享组件',
                license='Apache-2.0', homepage=f'https://huggingface.co/{repo}',
                purpose='ocr', files=files, suggestedRamGb=4,
                memoryNote='实际运行内存由模型组合、输入尺寸和计算后端决定。')


def main():
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        components = list(pool.map(resolve, REVISIONS.items()))
    def preset(id, name, tier, det, rec, groups, languages, parameters, description, ram):
        return dict(id=id, name=name, tier=tier, detection=component_id(det),
                    recognition=component_id(rec), groups=groups, languages=languages,
                    parameters=parameters, description=description, suggestedRamGb=ram,
                    license='Apache-2.0', legacy=False)
    presets = []
    for tier, params, ram, desc in [
        ('small','约 7.7M（官方组合）',6,'兼顾速度与精度，适合中高性能手机、平板和桌面设备。'),
        ('medium','约 34.5M（官方组合）',16,'高精度，适合较高性能设备；计算量和运行内存更高。'),
    ]:
        groups = ['chinese','english','latin','japanese']
        langs = ['zh-Hans','zh-Hant','en'] + LATIN + ['ja']
        presets.append(preset(f'ppocr-v6-{tier}', f'PP-OCRv6 {tier.title()}', tier,
                       f'PP-OCRv6_{tier}_det_onnx', f'PP-OCRv6_{tier}_rec_onnx',
                       groups, langs, params, desc, ram))
    presets.append(preset('ppocr-v5-mobile','PP-OCRv5 Mobile','mobile',
                   'PP-OCRv5_mobile_det_onnx','PP-OCRv5_mobile_rec_onnx',
                   ['chinese','english','japanese'],['zh-Hans','zh-Hant','en','ja'],
                   '上游未单列组合参数量','成熟的中英日移动端备选。',4))
    for prefix, group, label, languages in [
        ('en','english','英文专用',['en']),
        ('korean','korean','韩英专用',['ko','en']),
        ('latin','latin','拉丁语专用',LATIN),
    ]:
        presets.append(preset(f'ppocr-v5-{prefix}',f'PP-OCRv5 {label}','language',
                       'PP-OCRv6_tiny_det_onnx',f'{prefix}_PP-OCRv5_mobile_rec_onnx',
                       [group] + (['english'] if prefix == 'korean' else []),languages,
                       '上游未单列组合参数量','针对所列语言优化识别，共享轻量文字检测组件。',4))
    # Local-only compatibility entries: no embedded payload and no invented URL.
    old_root = Path('assets/models/ocr')
    old_det = 'ch_PP-OCRv4_det_mobile.onnx'
    old_dicts = ['ppocr_keys_v1.txt','en_dict.txt','japan_dict.txt','korean_dict.txt','latin_dict.txt']
    old_recs = ['ch_PP-OCRv4_rec_mobile.onnx','en_PP-OCRv4_rec_mobile.onnx',
                'japan_PP-OCRv4_rec_mobile.onnx','korean_PP-OCRv4_rec_mobile.onnx','latin_PP-OCRv3_rec_mobile.onnx']
    for group, rec, dictionary in zip(['chinese','english','japanese','korean','latin'],old_recs,old_dicts):
        id = f'ocr-legacy-{group}'
        files=[]
        for filename in [old_det,rec,dictionary]:
            data=(old_root/filename).read_bytes()
            files.append(dict(name=filename,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),sources={}))
        components.append(dict(id=id,name=f'旧版 OCR · {group}',engine='ppocr-legacy',
            revision=hashlib.sha256(json.dumps(files,sort_keys=True).encode()).hexdigest(),
            parameters='上游未单列',quantization='FP32 · ONNX',languages=[group],
            description='已安装的旧版兼容模型，仅支持从原数据目录迁移或离线导入。',
            license='沿用原模型许可',homepage='https://github.com/PaddlePaddle/PaddleOCR',
            purpose='ocr',files=files,suggestedRamGb=4,memoryNote='旧版兼容模型。'))
        presets.append(dict(id=f'legacy-{group}',name='旧版兼容',tier='legacy',detection=id,
            recognition=id,groups=[group],languages=[group],parameters='上游未单列',
            description='复用此前已安装的模型；可另下载新版模型。',suggestedRamGb=4,
            license='沿用原模型许可',legacy=True))
    target=Path('assets/models/ocr_catalog.json')
    target.write_text(json.dumps(dict(version=1,verifiedOn='2026-10-23',components=components,presets=presets),
                                  ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'Wrote {len(components)} components and {len(presets)} presets to {target}')


if __name__=='__main__':
    main()
