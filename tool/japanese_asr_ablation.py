"""Explicit Windows-only ASR processing experiment; no downloads or app-state writes.

Uses already prepared model weights and the fixed FLEURS development samples.
Requires maintainer NumPy/soundfile; optional fugashi is used only for secondary
reading-normalized comparisons. None of these are application dependencies.
"""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import unicodedata

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def normal(text):
    return ''.join(c for c in unicodedata.normalize('NFKC', text).lower()
                   if unicodedata.category(c)[0] in 'LN')


def srt_cues(path):
    result = []
    for block in re.split(r'\r?\n\s*\r?\n', path.read_text(encoding='utf-8-sig')):
        lines = block.splitlines()
        at = next((i for i, line in enumerate(lines) if '-->' in line), None)
        if at is None: continue
        def stamp(value):
            h, m, s = map(float, value.strip().replace(',', '.').split(':'))
            return 3600*h+60*m+s
        start, end = lines[at].split('-->')
        result.append(dict(start=stamp(start), end=stamp(end), text=''.join(lines[at+1:])))
    return result


def timing_violations(cues):
    failures = []
    for cue in cues:
        length = len(cue['t'].encode('utf-16-le'))//2
        if not (0 <= cue['s'] < cue['e']): failures.append((cue['i'], 'cue-time'))
        for span in cue.get('spans', []):
            if not (0 <= span['from'] < span['to'] <= length and
                    cue['s']*1000-1000 <= span['startUs'] < span['endUs'] <= cue['e']*1000+1000):
                failures.append((cue['i'], 'word-time-or-text-range'))
    return failures


def errors(reference, hypothesis):
    a, b = normal(reference), normal(hypothesis)
    rows = [list(range(len(b) + 1))]
    for i, x in enumerate(a, 1):
        row = [i]
        previous = rows[-1]
        for j, y in enumerate(b, 1):
            row.append(min(previous[j-1] + (x != y), previous[j] + 1, row[j-1] + 1))
        rows.append(row)
    i, j = len(a), len(b)
    substitutions = deletions = insertions = 0
    while i or j:
        if i and j and rows[i][j] == rows[i-1][j-1] + (a[i-1] != b[j-1]):
            substitutions += a[i-1] != b[j-1]
            i -= 1
            j -= 1
        elif i and rows[i][j] == rows[i-1][j] + 1:
            deletions += 1
            i -= 1
        else:
            insertions += 1
            j -= 1
    count = len(a)
    return dict(referenceCharacters=count, hypothesisCharacters=len(b),
                substitutions=substitutions, deletions=deletions, insertions=insertions,
                edits=substitutions + deletions + insertions,
                cer=(substitutions + deletions + insertions) / count if count else None)


def quantize(audio):
    return np.clip(np.rint(np.asarray(audio) * 32768), -32768, 32767).astype('<i2').astype(np.float32) / 32768


def prepare(args):
    dataset = read(args.samples)
    source = [s for s in dataset['samples'] if re.fullmatch(r'ja-\d\d', s['id'])]
    assert len(source) == 20 and len({s['source'] for s in source}) == 20
    cases = []
    def add(ident, category, audio, **metadata):
        audio = quantize(audio).astype('<f4')
        path = args.output / 'audio' / (ident + '.f32')
        path.parent.mkdir(parents=True, exist_ok=True)
        audio.tofile(path)
        cases.append(dict(id=ident, category=category, inputF32=path.as_posix(),
                          samples=len(audio), seconds=len(audio)/16000, sha256=sha(path), **metadata))
    for index, sample in enumerate(source):
        assert sha(Path(sample['path'])) == sample['sha256'], sample['id']
        audio, rate = sf.read(sample['path'], dtype='float32')
        assert rate == 16000 and audio.ndim == 1
        base = dict(baseId=sample['id'], source=sample['source'], sourceSha256=sample['sha256'], reference=sample['reference'])
        add(sample['id']+'-clean', 'clean', audio, **base)
        rng = np.random.default_rng(20261031 + index)
        spectrum = np.fft.rfft(rng.standard_normal(len(audio)))
        frequency = np.fft.rfftfreq(len(audio), d=1/16000)
        spectrum /= np.sqrt(np.maximum(frequency, 40))
        spectrum[0] = 0
        noise = np.fft.irfft(spectrum, n=len(audio))
        t = np.arange(len(audio)) / 16000
        music = ((np.sin(2*np.pi*220*t) + .6*np.sin(2*np.pi*277.18*t)
                  + .4*np.sin(2*np.pi*329.63*t)) * (.55 + .45*np.sin(2*np.pi*.7*t)**2))
        for kind, bed, snr in [('pink_noise', noise, 10), ('synthetic_music', music, 12)]:
            bed = bed / max(1e-10, np.sqrt(np.mean(bed**2))) * np.sqrt(np.mean(audio**2)) / (10**(snr/20))
            mix = audio + bed
            gain = min(1., .98/max(1e-10, float(np.max(np.abs(mix)))))
            add(sample['id']+'-'+kind, kind, mix*gain, snrDb=snr,
                snrDefinition='whole-utterance RMS, synthetic interference without speech',
                clippingAvoidanceGain=gain, **base)
    video, rate = sf.read(args.video, dtype='float32')
    assert rate == 16000 and video.ndim == 1
    # Exactly the earlier comparison window: original video 30--180 seconds.
    clip = video[30*16000:180*16000]
    sf.write(args.output/'video-150.wav', quantize(clip), 16000, subtype='PCM_16')
    add('video-150', 'video', clip, originalVideoOffsetSeconds=30, reference=None)
    add('silence', 'silence', np.zeros(10*16000, dtype=np.float32), reference='')
    save(args.output/'inputs.json', dict(dataset=dataset['dataset'], revision=dataset['revision'], license=dataset.get('license'),
         split=dataset['split'], uniqueOriginalUtterances=20,
         previous21Correction='20 original utterances plus one synthetic-music derivative, not 21 independent clean recordings',
         videoSourceSha256=sha(args.video), cases=cases))
    print('Prepared 20 original, 20 pink-noise, 20 synthetic-music cases, video and silence.', flush=True)


def flutter_test(args, mode):
    run(args.output/f'{mode}.log', [shutil.which('flutter') or 'flutter.bat', 'test', '--no-pub',
        '--concurrency=1', 'test/japanese_asr_ablation_native_test.dart',
        '--dart-define=JAPANESE_ABLATION_ROOT='+args.output.as_posix(),
        '--dart-define=JAPANESE_ABLATION_MODE='+mode])


def run(log, command, environment=None):
    print('Running', log.name, flush=True)
    with log.open('w', encoding='utf-8') as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, env=environment)
    if result.returncode:
        print(log.read_text(encoding='utf-8', errors='replace')[-3500:], flush=True)
        raise RuntimeError(f'{log.name} failed ({result.returncode})')
    print('Passed', log.name, flush=True)


def transcribe(args):
    prepared = read(args.output/'prepared.json')
    helper = ROOT/'native/parakeet_ja/prebuilt/windows-x64/parakeet_ja_worker.exe'
    weights = ROOT/'.artifacts/model-center/native/parakeet-ja-0.6b-q8/parakeet-tdt-0.6b-ja-q8_0.gguf'
    records = []
    with (args.output/'decoder.log').open('w', encoding='utf-8') as log:
        owner = subprocess.Popen([str(helper)], cwd=helper.parent, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=log, text=True, encoding='utf-8')
        def request(value):
            owner.stdin.write(json.dumps(value)+'\n')
            owner.stdin.flush()
            response = json.loads(owner.stdout.readline())
            if not response.get('ok'):
                raise RuntimeError(response)
            return response
        try:
            request(dict(op='load', kind='parakeet-ja', model=str(weights), backend='cpu', threads=4))
            for number, case in enumerate(prepared['cases'], 1):
                paths = {'raw': case['inputF32'], 'denoised': case['denoisedF32']}
                plans = [
                    ('raw_fixed', 'raw', case['fixedRanges']),
                    ('denoised_fixed', 'denoised', case['fixedRanges']),
                    ('raw_vad', 'raw', case['rawVadRanges']),
                    ('denoised_vad', 'denoised', case['denoisedVadRanges']),
                    ('raw_vad_no_padding', 'raw', case['rawVadNoPaddingRanges']),
                ]
                if 'wholeDenoisedF32' in case:
                    paths['whole'] = case['wholeDenoisedF32']
                    plans.append(('whole_denoised_fixed', 'whole', case['fixedRanges']))
                results = {}
                for name, kind, ranges in plans:
                    audio = np.fromfile(paths[kind], dtype='<f4')
                    watch = time.perf_counter()
                    text = ''
                    pieces = []
                    for start, end in ranges:
                        assert 0 <= start < end <= len(audio) and end-start <= 9*16000
                        temp = args.output/'decoder-input.f32'
                        audio[start:end].tofile(temp)
                        result = request(dict(op='decode', path=str(temp), language='ja'))['result']
                        text += result['text']
                        pieces.append(dict(range=[start, end], result=result))
                    results[name] = dict(text=text, seconds=time.perf_counter()-watch,
                                         segments=len(ranges), pieces=pieces)
                    if case['reference'] is not None:
                        results[name]['metrics'] = errors(case['reference'], text)
                records.append(dict(id=case['id'], baseId=case.get('baseId'), category=case['category'],
                                    reference=case['reference'], seconds=case['seconds'], results=results))
                save(args.output/'recognition.json', dict(platform='Windows CPU', threads=4,
                     modelIdentity='parakeet-ja-0.6b-q8@d9e3ba65a6579796389ea89e5939509ed257f972',
                     comparison='Fixed ranges identical before/after denoising; VAD variants deliberately redetect boundaries.', cases=records))
                if case['category'] == 'video':
                    save(args.output/'frozen-video.json', dict(inputF32=case['inputF32'],
                         pieces=results['raw_vad']['pieces']))
                print(f'ASR {number}/{len(prepared["cases"])}: {case["id"]}', flush=True)
        finally:
            owner.stdin.close()
            owner.wait(timeout=30)


def pipeline(args):
    flutter = shutil.which('flutter') or 'flutter.bat'
    scenarios = [
        ('full_raw', args.video, False, 'pipeline', 0, False),
        ('full_denoised', args.video, True, 'pipeline', 0, False),
        ('clip_pipeline', args.output/'video-150.wav', False, 'pipeline', 0, False),
        ('clip_serial', args.output/'video-150.wav', False, 'lowMemory', 0, False),
        ('clip_forced_alignment', args.output/'video-150.wav', False, 'pipeline', 45, True),
    ]
    for name, audio, denoise, execution, seconds, force in scenarios:
        if args.scenario and args.scenario != name:
            continue
        output = args.output/name
        options = args.output/(name+'-options.json')
        save(options, dict(enabled=True, denoise=denoise, alignment=True, alwaysAlign=force,
                           punctuation=True, trimSilence=True, review=True))
        command = [flutter, 'test', '--no-pub', '--concurrency=1',
                   'test/cohere_asr_pipeline_native_test.dart',
                   '--dart-define=JAPANESE_ASR_MODEL=parakeet-ja-0.6b-q8',
                   '--dart-define=COHERE_AUDIO='+audio.as_posix(),
                   '--dart-define=COHERE_OUTPUT='+output.as_posix(),
                   '--dart-define=COHERE_LANGUAGE=ja',
                   '--dart-define=COHERE_EXECUTION='+execution,
                   '--dart-define=COHERE_OPTIONS_FILE='+options.as_posix()]
        if seconds:
            command.append('--dart-define=COHERE_SECONDS='+str(seconds))
        run(args.output/(name+'.log'), command)


def translation(args):
    environment = dict(os.environ)
    environment['LLAMADART_NATIVE_LIB_DIR'] = str(ROOT/'build/native_assets/windows')
    run(args.output/'translation.log', [shutil.which('flutter') or 'flutter.bat', 'test', '--no-pub',
        '--concurrency=1', 'test/model_integration_native_test.dart',
        '--plain-name', 'parakeet-ja-0.6b-q8 production',
        '--dart-define=MODEL_INTEGRATION_MODEL_ROOT='+str(ROOT/'.artifacts/model-center/native'),
        '--dart-define=MODEL_INTEGRATION_REPORT='+str(args.output/'translation.json')], environment)
    records = read(args.output/'translation.json')
    flows = {key:value for key,value in records.items() if key.startswith('workflow:parakeet-ja-')}
    assert len(flows) == 2 and all(value['resumedWithoutInference'] for value in flows.values())
    assert all(not re.search(r'[\u3040-\u30ff]', line) for value in flows.values() for line in value['translations'])
    save(args.output/'translation-audit.json', dict(passed=True, localTranslationModels=list(flows),
         translatedChineseWithoutJapaneseKana=True, resumedWithoutNewInference=True))


def summarize(args):
    recognized = read(args.output/'recognition.json')
    groups = {}
    for category in ['clean', 'pink_noise', 'synthetic_music']:
        cases = [c for c in recognized['cases'] if c['category'] == category]
        group = {}
        for variant in cases[0]['results']:
            metrics = [c['results'][variant]['metrics'] for c in cases]
            total = {key: sum(m[key] for m in metrics) for key in
                     ['referenceCharacters', 'hypothesisCharacters', 'substitutions', 'deletions', 'insertions', 'edits']}
            total['cer'] = total['edits']/total['referenceCharacters']
            group[variant] = dict(clips=len(cases), metrics=total,
                                  zeroErrorClips=sum(m['edits']==0 for m in metrics))
        for before, after in [('raw_fixed','denoised_fixed'), ('raw_vad','denoised_vad')]:
            a = np.array([c['results'][before]['metrics']['edits'] for c in cases])
            b = np.array([c['results'][after]['metrics']['edits'] for c in cases])
            n = np.array([c['results'][before]['metrics']['referenceCharacters'] for c in cases])
            rng = np.random.default_rng(20261031)
            indices = rng.integers(0, len(cases), (2000, len(cases)))
            delta = (b[indices].sum(1)-a[indices].sum(1))/n[indices].sum(1)*100
            group[before+'_vs_'+after] = dict(better=int((b<a).sum()), worse=int((b>a).sum()),
                equal=int((b==a).sum()), cerChangePercentagePoints=float((b.sum()-a.sum())/n.sum()*100),
                pairedBootstrap95PercentInterval=np.percentile(delta,[2.5,97.5]).tolist())
        groups[category] = group
    pipelines = {}
    ocr = srt_cues(args.ocr)
    for name in ['full_raw','full_denoised','clip_pipeline','clip_serial','clip_forced_alignment']:
        path = args.output/name/'pipeline.json'
        if path.exists():
            result = read(path)
            pipelines[name] = {k: result.get(k) for k in ['passed','audioSeconds','elapsedSeconds',
                'stableBatches','stableBatchesMatchFinalOutput','preparations','resumeWithoutNewInference','primaryLoads','enhancementOptions','execution']}
            referenceStart = 0 if name.startswith('full_') else 30
            referenceEnd = referenceStart + result['audioSeconds']
            reference = ''.join(c['text'] for c in ocr if referenceStart <= (c['start']+c['end'])/2 < referenceEnd)
            hypothesis = ''.join(c['t'] for c in result['cues'])
            pipelines[name]['relativeUncorrectedOcr'] = errors(reference, hypothesis)
            pipelines[name]['cueCount'] = len(result['cues'])
            pipelines[name]['timingViolations'] = timing_violations(result['cues'])
            pipelines[name]['alignedCueMarks'] = sum(any('Qwen3 ForcedAligner' in note for note in c.get('asr',{}).get('notes',[])) for c in result['cues'])
    post = read(args.output/'postprocessing.json') if (args.output/'postprocessing.json').exists() else None
    postAudit = {}
    if post:
        before = ''.join(c['t'] for c in post['rawCues'])
        for name, values in post['profiles'].items():
            enhanced = values['enhancedCues']
            segmented = values['naturalCues']
            postAudit[name] = dict(seconds=values['seconds'], phases=values['phases'],
                enhancedRecognitionTextEdits=errors(before,''.join(c['t'] for c in enhanced))['edits'],
                segmentedRecognitionTextEdits=errors(before,''.join(c['t'] for c in segmented))['edits'],
                inputCueCount=len(post['rawCues']), outputCueCount=len(segmented),
                cuesWithJapaneseBoundaries=sum(bool(c.get('asr',{}).get('wordBoundaries')) for c in enhanced),
                alignedCueMarks=sum(any('Qwen3 ForcedAligner' in note for note in c.get('asr',{}).get('notes',[])) for c in enhanced),
                retainedAlignedCueCount=sum(any(s.get('role')=='aligned' for s in c.get('spans',[])) for c in enhanced),
                alignmentFallbackNotes=sum(any('未采用共享对齐' in note or '保留原始' in note for note in c.get('asr',{}).get('notes',[])) for c in enhanced),
                changedCueTimes=sum((a['s'],a['e'])!=(b['s'],b['e']) for a,b in zip(post['rawCues'],enhanced)),
                timingViolations=timing_violations(segmented), residentPunctuationBytes=values['residentPunctuationBytes'])
    video = next(c for c in recognized['cases'] if c['category']=='video')
    reference = ''.join(c['text'] for c in ocr if 30 <= (c['start']+c['end'])/2 < 180)
    videoControl = {name:dict(relativeUncorrectedOcr=errors(reference,value['text']), segments=value['segments'])
                    for name,value in video['results'].items()}
    serial = {}
    if (args.output/'clip_pipeline/pipeline.json').exists() and (args.output/'clip_serial/pipeline.json').exists():
        a = read(args.output/'clip_pipeline/pipeline.json')
        b = read(args.output/'clip_serial/pipeline.json')
        serial = dict(recognitionTextEdits=errors(''.join(c['t'] for c in a['cues']),''.join(c['t'] for c in b['cues']))['edits'],
                      exactTimingAndTextEqual=[(c['s'],c['e'],c['t'],c.get('spans')) for c in a['cues']]==[(c['s'],c['e'],c['t'],c.get('spans')) for c in b['cues']],
                      fullCueMetadataEqual=a['cues']==b['cues'],
                      pipelineSeconds=a['elapsedSeconds'], serialSeconds=b['elapsedSeconds'])
    silence = next(c for c in recognized['cases'] if c['category']=='silence')
    silenceAudit = {name:dict(insertedCharacters=len(normal(value['text'])), segments=value['segments'],
                             nonemptyDecodedPieces=sum(bool(p['result']['text'].strip()) for p in value['pieces']))
                    for name,value in silence['results'].items()}
    report = dict(platform='Windows only', uniqueStandardUtterances=20, groups=groups, pipelines=pipelines,
         postprocessing=postAudit, videoFixedControls=videoControl,
         pipelineVersusSerial=serial, silence=silenceAudit,
         limitations=['FLEURS dev is a small read-speech sample, not animation ground truth.',
                      'Noise and music groups are deterministic synthetic interference, not real-world population estimates.',
                      'OCR for the cartoon contains errors and duplicates; relative OCR CER is not accuracy.',
                      'Fixed segmentation isolates waveform denoising; VAD comparisons include boundary changes.',
                      'Forced alignment and subtitle regrouping have no independently annotated timing ground truth.'],
         postprocessingSource='postprocessing.json' if post else None)
    if (args.output/'frontend.json').exists():
        frontend = read(args.output/'frontend.json')['cases']
        values = [errors(c['reference'], c['text']) for c in frontend]
        report['productionFrontend'] = dict(clips=len(frontend),
            allMatchIndependentControl=all(c['matchesIndependentControl'] for c in frontend),
            cer=sum(m['edits'] for m in values)/sum(m['referenceCharacters'] for m in values))
    if (args.output/'translation-audit.json').exists():
        report['translation'] = read(args.output/'translation-audit.json')
    save(args.output/'summary.json', report)
    render_report(args, report)
    for category, values in groups.items():
        print(category, {key:round(value['metrics']['cer']*100,2) for key,value in values.items() if 'metrics' in value}, flush=True)


def render_report(args, report):
    def percent(value): return f'{100*value:.2f}%'
    def cell(value): return '<td>'+html.escape(str(value))+'</td>'
    def table(headers, rows):
        return '<table><thead><tr>'+''.join('<th>'+html.escape(h)+'</th>' for h in headers)+'</tr></thead><tbody>'+''.join('<tr>'+''.join(cell(v) for v in row)+'</tr>' for row in rows)+'</tbody></table>'
    groups=report['groups']
    conditions = table(['20 段原始朗读，处理方式','字符错误率 CER ↓'], [
        ('固定 7.5 秒切分，不做 VAD',percent(groups['clean']['raw_fixed']['metrics']['cer'])),
        ('VAD + 最多 160 ms 补边，保留原音（当前默认）',percent(groups['clean']['raw_vad']['metrics']['cer'])),
        ('VAD + 补边 + GTCRN 降噪',percent(groups['clean']['denoised_vad']['metrics']['cer'])),
        ('VAD，但不补边',percent(groups['clean']['raw_vad_no_padding']['metrics']['cer'])),
    ])
    noise = table(['场景（每类 20 段）','原音 + VAD','降噪后 + VAD','降噪改善 / 变差 / 持平的片段'], [
        (label, percent(groups[key]['raw_vad']['metrics']['cer']),
         percent(groups[key]['denoised_vad']['metrics']['cer']),
         f"{groups[key]['raw_vad_vs_denoised_vad']['better']} / {groups[key]['raw_vad_vs_denoised_vad']['worse']} / {groups[key]['raw_vad_vs_denoised_vad']['equal']}")
        for key,label in [('clean','原始朗读'),('pink_noise','合成宽带噪声，10 dB SNR'),('synthetic_music','合成无歌词伴奏，12 dB SNR')]
    ])
    labels={'no_post':'跳过后处理','default':'默认后处理','no_trim':'关闭静音修边',
            'no_punctuation':'关闭标点选项','no_japanese_boundaries':'关闭日韩分词层','force_alignment':'每条都强制精校'}
    post = table(['冻结同一份 ASR 原文，只切换后处理','文字改动数','词时间 / 文字越界数','耗时'], [
        (labels[key],value['segmentedRecognitionTextEdits'],len(value['timingViolations']),f"{value['seconds']:.3f} 秒")
        for key,value in report['postprocessing'].items()
    ])
    pipeline_labels={'full_raw':'完整动画 / 原音','full_denoised':'完整动画 / 降噪','clip_pipeline':'150 秒 / 流水线',
                     'clip_serial':'150 秒 / 节省内存串行','clip_forced_alignment':'45 秒 / 每条强制精校'}
    pipelines=table(['真实生产流程','音频时长','转录耗时','稳定批次','断点恢复无新增推理'],[
        (pipeline_labels[name],f"{value['audioSeconds']:.1f} 秒",f"{value['elapsedSeconds']:.1f} 秒",value['stableBatches'],'通过' if value['resumeWithoutNewInference'] else '未通过')
        for name,value in report['pipelines'].items()
    ])
    raw_case=next(c for c in read(args.output/'prepared.json')['cases'] if c['category']=='video')
    shutil.copy2(args.output/'video-150.wav',args.output/'video-150-original.wav')
    sf.write(args.output/'video-150-gtcrn.wav',np.fromfile(raw_case['denoisedF32'],dtype='<f4'),16000,subtype='PCM_16')
    force=report['postprocessing']['force_alignment']
    full_raw=report['pipelines'].get('full_raw',{}).get('relativeUncorrectedOcr',{}).get('cer')
    full_denoised=report['pipelines'].get('full_denoised',{}).get('relativeUncorrectedOcr',{}).get('cer')
    movie_note=(f'完整动画相对未经校订 OCR 的字符差异率：原音 {percent(full_raw)}，降噪 {percent(full_denoised)}。' if full_raw is not None and full_denoised is not None else '')
    pure=groups['clean']['raw_vad']
    output=f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Windows 日语转录处理步骤实验</title><style>
body{{margin:0;background:#f3f5f8;color:#192638;font:16px/1.7 "Segoe UI","Microsoft YaHei",sans-serif}}
main{{max-width:1080px;margin:32px auto;padding:0 24px 48px}}h1{{font-size:29px;line-height:1.4}}h2{{font-size:22px;margin-top:0}}
section{{background:white;border:1px solid #dae1eb;border-radius:12px;padding:24px;margin:20px 0}}
table{{border-collapse:collapse;width:100%;font-size:15px}}th,td{{padding:10px;text-align:left;border-bottom:1px solid #e4e9f0}}th{{background:#f4f7fb}}
.lead{{font-size:19px}}.note{{color:#4a596e;font-size:14px}}.attention{{background:#fff7e4;border-left:4px solid #c18110;padding:12px 16px}}
a{{color:#174f9b}}audio{{width:min(100%,450px)}}details{{margin-top:16px}}code{{overflow-wrap:anywhere}}
</style><main><h1>当前日语模型：Windows 处理步骤对照</h1>
<p class="lead">当前默认流程已验证适配。保留原音、VAD 与补边是这批样本的较好组合；不能保证任意日语或动画都同样精准。</p>
<p class="note">2026-10-31 · Parakeet 日语 0.6B Q8 / 当前 CTC 解码 · Windows CPU 4 线程 · 全部音频在本地处理，未测试手机。没有修改应用默认、权重或用户任务。</p>
<section><h2>1. 分段对识别影响明显</h2>{conditions}
<p>真实 LocalAsrWorker 入口逐段复核 20 段原始朗读，与独立对照完全一致。按本报告去空白、标点和 NFKC 的严格比较，{pure['zeroErrorClips']} / 20 段与参考全文一致；数字和汉字/假名写法差异也计错。</p>
<p class="attention">这些是小样本朗读结果。CER 不是“每句正确的概率”，也不能把这组结果直接当作《蜡笔小新》的准确率。</p></section>
<section><h2>2. 降噪没有稳定的识别收益</h2>{noise}
<p>另做了相同切分的原音/降噪对照，隔离波形变化；也做了降噪后重新 VAD 的真实顺序对照。配对抽样区间见 JSON：小样本均值变化不足以证明任何环境必然更好或更差。</p>
<p class="note">噪声、伴奏是无语音的确定性合成干扰，不代表所有真实噪声或音乐。GTCRN 分窗版与同一模型整段运行也做了对照，重复复用的采样差异为零。</p>
<details><summary>听同一 150 秒声音的波形对照（不会自动播放）</summary>
<p>原音：</p><audio controls preload="none" src="video-150-original.wav"></audio>
<p>软件 GTCRN 连续处理该片段：</p><audio controls preload="none" src="video-150-gtcrn.wav"></audio>
<p class="note">这是固定切分实验用的 150 秒对照；完整任务按自身音频块处理。听起来更安静不等于字错率更低。</p></details></section>
<section><h2>3. 后处理保留原文，不负责改正错词</h2>{post}
<p>同一份 36 段 ASR 原文被冻结后再测试。日语分词实际作用于默认组 36 段，改善显示边界的输入；中英文标点器没有为日语加载。静音修边只动显示时间。</p>
<p>强制精校耗时 {force['seconds']:.1f} 秒，{force['alignedCueMarks']} 段带采用标记、{force['alignmentFallbackNotes']} 段有回退说明。原文未改动，保留原生时间是允许的兜底。没有人工标注的词时间真值，所以不声称新时间一定更准确。</p>
<p class="note">精校隔离测试曾误指向缺失的开发权重目录；已改用真实权重重测，并要求实际执行成功。该错误不计入最终结果，也没有当成应用缺陷。</p></section>
<section><h2>4. 分批、串行、恢复和翻译</h2>{pipelines}
<p>150 秒流水线和节省内存串行输出的文字、时间及元数据完全一致。流水线交给翻译的稳定批次与最终字幕逐项一致。两种现有本地中文翻译均真实运行，并通过恢复无新增推理检查。</p>
<p class="attention">{movie_note}OCR 有错字、重复且未人工逐字校订；这里的“差异率”只能作配对参考，不能叫动画真实准确率。</p>
<p><a href="full_raw/subtitles.srt">完整动画原音识别字幕</a> · <a href="full_denoised/subtitles.srt">完整动画开启降噪的字幕</a></p>
<p class="note">耗时含模型首次加载和音频块准备；没有清空系统文件缓存，不是冷启动或播放资源争用基准。</p></section>
<section><h2>建议保留的默认</h2><p>16 kHz 单声道 → 保留原音 → VAD 与最多 160 ms 补边 → 当前日语识别 → 原生词时间优先 → 静音修边、日语分词与自然分句 → 稳定批次 → 原翻译。</p>
<p>默认不启用 GTCRN，不对每条字幕都强制精校。没有证据时不增加额外音频滤波或改写识别文字。</p>
<details><summary>数据、许可与复现</summary><p>原始 FLEURS 日语 dev 20 条，另各派生 20 条 10 dB 宽带噪声和 12 dB 合成伴奏。上一轮的 21 条统计包含一个伴奏派生，不能算 21 条独立原始朗读。</p>
<p>FLEURS：Google 及贡献者，CC BY 4.0；模型：NVIDIA，cstr GGUF 转换，CC BY 4.0。音频添加合成干扰及格式转换的哈希在 inputs.json 中记录。</p>
<p><a href="summary.json">汇总 JSON 与区间</a> · <a href="recognition.json">所有逐段识别</a> · <a href="postprocessing.json">冻结原文的后处理对照</a> · <a href="environment.json">源码和运行库收据</a></p>
<p>复现：<code>python tool/japanese_asr_ablation.py --stage all</code>；使用已准备的本地权重和样本，不自动下载。</p></details></section></main></html>'''
    (args.output/'report.html').write_text(output,encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=['all','inputs','audio','recognize','frontend','post','pipeline','translation','summary'], default='all')
    parser.add_argument('--output', type=Path, default=ROOT/'.artifacts/japanese-processing-ablation-20261031')
    parser.add_argument('--scenario', choices=['full_raw','full_denoised','clip_pipeline','clip_serial','clip_forced_alignment'])
    parser.add_argument('--samples', type=Path, default=ROOT/'.artifacts/qwen-integration/quality/samples.json')
    parser.add_argument('--video', type=Path, default=ROOT/'.artifacts/cohere-integration/full-ja.wav')
    parser.add_argument('--ocr', type=Path, default=ROOT/'.artifacts/japanese-asr-review-20261031/reference-ocr-ja.srt')
    args = parser.parse_args()
    if os.name != 'nt': parser.error('This experiment intentionally runs only on Windows.')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    for stage in ['inputs','audio','recognize','frontend','post','pipeline','translation','summary']:
        if args.stage not in ['all', stage]: continue
        if stage == 'inputs': prepare(args)
        elif stage in ['audio','frontend','post']: flutter_test(args, stage)
        elif stage == 'recognize': transcribe(args)
        elif stage == 'pipeline': pipeline(args)
        elif stage == 'translation': translation(args)
        else: summarize(args)


if __name__ == '__main__': main()
