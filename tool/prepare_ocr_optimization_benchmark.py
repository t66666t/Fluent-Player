"""Capture the pre-optimization OCR sources and stage an opt-in ABBA test.

No weights are downloaded. Run the generated Flutter test from the repository
root with --no-pub and --concurrency=1. The original tracked OCR sources must
have been clean before this optimization; the baseline is read from Git HEAD.
"""
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / '.artifacts/ocr-optimization-20261026'


def main():
    baseline = OUTPUT / 'baseline'
    if baseline.exists():
        raise SystemExit(f'Baseline already captured: {baseline}')
    baseline.mkdir(parents=True)
    revision = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    paths = subprocess.check_output(
        ['git', 'ls-files', 'lib/services/ocr_*.dart'], cwd=ROOT,
        text=True).splitlines()
    names = {Path(path).name for path in paths}
    for path in paths:
        source = subprocess.check_output(
            ['git', 'show', f'{revision}:{path}'], cwd=ROOT).decode('utf-8')

        def rebind(match):
            directive, ref = match.groups()
            if ref.startswith(('dart:', 'package:')) or ref in names:
                return match.group(0)
            resolved = (ROOT / 'lib/services' / ref).resolve().relative_to(ROOT / 'lib')
            return f"{directive} 'package:video_player_app/{resolved.as_posix()}'"

        (baseline / Path(path).name).write_text(
            re.sub(r"(import|export) '([^']+)'", rebind, source), encoding='utf-8')
    (OUTPUT / 'baseline.json').write_text(json.dumps({
        'revision': revision,
        'sources': paths,
    }, indent=2), encoding='utf-8')
    (OUTPUT / 'comparison_test.dart').write_text(TEST, encoding='utf-8')
    print(OUTPUT / 'comparison_test.dart')


TEST = r"""
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'baseline/ocr_model_manager.dart' as before_model;
import 'baseline/ocr_subtitle_manager.dart' as before;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) DynamicLibrary.open(File('windows/runtime/onnxruntime.dll').absolute.path);
  test('same weights, video and regions: before/after/after/before', () async {
    SharedPreferences.setMockInitialValues({});
    final previousStorage = AppStorageService.instance;
    final root = await Directory.systemTemp.createTemp('ocr-performance-');
    final storage = AppStorageService(locations: () async => StorageLocations(
      platform: StoragePlatform.linux, support:Directory('${root.path}/support'),
      documents:Directory('${root.path}/documents'),defaultData:Directory('${root.path}/data'),
      executable:Directory('${root.path}/bin')));
    AppStorageService.instance=storage;
    await storage.initialize();
    final center=ModelCenterService(storage:storage);
    final models=OcrModelManager(center:center);
    final oldModels=before_model.OcrModelManager(center:center);
    final video=File('.artifacts/ocr-upgrade/fixture/comparison-60s.mp4').absolute.path;
    final library=_Library(root,video);
    final records=<Map<String,Object?>>[];
    try {
      await models.initialize();
      for(final id in ['ocr-v6-small-det','ocr-v6-small-rec','ocr-v5-mobile-det','ocr-v5-mobile-rec']) {
        await center.importFiles(id,Directory('.artifacts/ocr-upgrade/models/$id'));
      }
      for(final model in ['ppocr-v6-small','ppocr-v5-mobile']) {
        for(final regions in [1,2]) {
          String? expected;
          for(final mode in ['warm-before','warm-after','before','after','after','before']) {
            final warmup=mode.startsWith('warm-');
            final tracks=List.generate(regions,(i)=>OcrSubtitleTrack(number:i+1,
              region:const NormalizedOcrRegion.subtitleDefault(),
              language:i==0?OcrSubtitleLanguage.chinese:OcrSubtitleLanguage.english,
              modelId:model));
            final request=OcrSubtitleJob(videoId:'comparison',videoPath:video,
              tracks:tracks,start:Duration.zero,end:Duration(seconds:warmup?(regions==1?5:30):60));
            final dynamic manager=mode.endsWith('before')
              ? before.OcrSubtitleManager(library:library,modelManager:oldModels)
              : OcrSubtitleManager(library:library,modelManager:models);
            var peak=ProcessInfo.currentRss;
            final poll=Timer.periodic(const Duration(milliseconds:50),(_){if(ProcessInfo.currentRss>peak)peak=ProcessInfo.currentRss;});
            final watch=Stopwatch()..start();
            try {
              await manager.start(request);
              watch.stop();
              final OcrSubtitleJob job=manager.job as OcrSubtitleJob;
              expect(job.status,OcrSubtitleJobStatus.completed,reason:job.error);
              expect(job.outputPaths.length,regions);
              final outputs=await Future.wait(job.outputPaths.map((path)=>File(path).readAsString()));
              if(warmup) continue;
              expected??=outputs.first;
              expect(outputs.every((value)=>value==expected),isTrue,
                reason:'Output/timestamps changed: $mode / $model / $regions');
              records.add({'mode':mode,'model':model,'regions':regions,'wallMs':watch.elapsedMilliseconds,
                'peakResidentBytes':peak,'outputs':outputs,'phases':manager.lastPerformance});
              debugPrint('$mode / $model / $regions regions: ${watch.elapsedMilliseconds} ms');
            } finally {poll.cancel();manager.dispose();}
          }
        }
      }
      await File('.artifacts/ocr-optimization-20261026/comparison.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({'platform':Platform.operatingSystem,
          'processors':Platform.numberOfProcessors,'mediaMs':60000,'order':'ABBA','records':records}));
    } finally {await center.shutdown();library.dispose();AppStorageService.instance=previousStorage;
      await root.delete(recursive:true);}
  },timeout:const Timeout(Duration(minutes:15)));
}
class _Library extends ChangeNotifier implements LibraryService {
  _Library(this.root,this.videoPath);
  final Directory root;final String videoPath;
  int sequence=0;
  @override VideoItem? getVideo(String id)=>VideoItem(id:id,path:videoPath,title:'Comparison',durationMs:60000,lastUpdated:0);
  @override Future<String> allocateSubtitleFile(String id,String preferredFileName)async {
    final dir=Directory('${root.path}/outputs');await dir.create(recursive:true);
    return '${dir.path}/${sequence++}-$preferredFileName';
  }
  @override Future<ManagedSubtitleAsset?> registerManagedLocalSubtitle(String videoId,{
    required String path,required ManagedSubtitleAssetKind kind,required String displayName,
    String? language,String? wordTimingPath,String? sourceAssetId,bool shareWithBilibiliPart=true})async=>null;
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
"""


if __name__ == '__main__':
    main()
