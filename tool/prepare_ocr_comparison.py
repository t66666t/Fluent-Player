"""Stage the saved pre-change OCR sources for a controlled native comparison.

Run before/after on the same video and legacy weights; this does not modify app
sources or packages. The baseline must be captured before applying the upgrade.
"""
from pathlib import Path
import argparse
import re
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cpu-baseline', action='store_true')
    args = parser.parse_args()
    artifact = Path('.artifacts/ocr-upgrade')
    baseline = artifact / 'baseline/lib/services'
    output = artifact / 'legacy_runtime'
    output.mkdir(parents=True, exist_ok=True)
    names = {p.name for p in baseline.glob('ocr_*.dart')}
    if len(names) != 5:
        raise SystemExit('Expected the five saved pre-change OCR service sources')
    for name in names:
        source = (baseline / name).read_text(encoding='utf-8')
        def rebind(match):
            directive, ref = match.groups()
            if ref.startswith(('dart:', 'package:')) or ref in names:
                return match.group(0)
            resolved = (Path('lib/services') / ref).resolve().relative_to(Path('lib').resolve())
            return f"{directive} 'package:video_player_app/{resolved.as_posix()}'"
        source = re.sub(r"(import|export) '([^']+)'", rebind, source)
        if args.cpu_baseline and name == 'ocr_processing_worker.dart':
            source = source.replace('preferHardwareAcceleration: true', 'preferHardwareAcceleration: false')
        (output / name).write_text(source, encoding='utf-8')
    video = artifact / 'fixture/comparison-60s.mp4'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                    '-stream_loop', '4', '-i', str(artifact / 'fixture/subtitles.mp4'),
                    '-t', '60', '-c', 'copy', str(video)], check=True)
    test = TEST.replace("'regions':regions,'wallMs'", "'regions':regions,'backend':manager.activeBackend,'wallMs'")
    if args.cpu_baseline:
        test = test.replace('[1,2]', '[1]').replace('comparison.json', 'comparison-cpu.json')
    (artifact / 'comparison_test.dart').write_text(test, encoding='utf-8')
    print(artifact / 'comparison_test.dart')


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
import 'legacy_runtime/ocr_model_manager.dart' as old_model;
import 'legacy_runtime/ocr_subtitle_manager.dart' as old;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) DynamicLibrary.open(File('windows/runtime/onnxruntime.dll').absolute.path);
  test('same model and video, alternating complete legacy/new workflows', () async {
    SharedPreferences.setMockInitialValues({});
    final previousStorage = AppStorageService.instance;
    final root = await Directory.systemTemp.createTemp('ocr-controlled-');
    final storage = AppStorageService(locations: () async => StorageLocations(
      platform: StoragePlatform.linux, support:Directory('${root.path}/support'),
      documents:Directory('${root.path}/documents'),defaultData:Directory('${root.path}/data'),
      executable:Directory('${root.path}/bin')));
    AppStorageService.instance=storage;
    await storage.initialize();
    final legacyDir=Directory('${root.path}/data/ocr_models/ppocr_v4_mobile');
    await legacyDir.create(recursive:true);
    for(final name in ['ch_PP-OCRv4_det_mobile.onnx','ch_PP-OCRv4_rec_mobile.onnx','ppocr_keys_v1.txt']) {
      await File('assets/models/ocr/$name').copy('${legacyDir.path}/$name');
    }
    final center=ModelCenterService(storage:storage);
    final models=OcrModelManager(rootOverride:Directory('${root.path}/data'),center:center);
    await models.initialize();
    final library=_Library(root,File('.artifacts/ocr-upgrade/fixture/comparison-60s.mp4').absolute.path);
    final records=<Map<String,Object?>>[];
    try {
      for(final regions in [1,2]) {
        for(final mode in ['old','new','new','old']) {
          final tracks=List.generate(regions,(i)=>OcrSubtitleTrack(number:i+1,
            region:const NormalizedOcrRegion.subtitleDefault(),language:OcrSubtitleLanguage.chinese));
          final request=OcrSubtitleJob(videoId:'comparison',videoPath:library.videoPath,
            tracks:tracks,start:Duration.zero,end:const Duration(seconds:60));
          final dynamic manager=mode=='old'
            ? old.OcrSubtitleManager(library:library,modelManager:old_model.OcrModelManager(rootOverride:Directory('${root.path}/data')))
            : OcrSubtitleManager(library:library,modelManager:models);
          var peak=ProcessInfo.currentRss;
          final poll=Timer.periodic(const Duration(milliseconds:100),(_){if(ProcessInfo.currentRss>peak)peak=ProcessInfo.currentRss;});
          final watch=Stopwatch()..start();
          try {
            await manager.start(request);
            watch.stop();
            final OcrSubtitleJob job=manager.job as OcrSubtitleJob;
            expect(job.status,OcrSubtitleJobStatus.completed,reason:job.error);
            final srt=await File(job.outputPaths.first).readAsString();
            records.add({'mode':mode,'regions':regions,'wallMs':watch.elapsedMilliseconds,
              'peakResidentBytes':peak,'srt':srt,
              if(mode=='new') 'phases':manager.lastPerformance});
            debugPrint('$mode / $regions regions: ${watch.elapsedMilliseconds} ms');
          } finally {poll.cancel();manager.dispose();}
        }
      }
      await File('.artifacts/ocr-upgrade/comparison.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({'platform':Platform.operatingSystem,
          'processors':Platform.numberOfProcessors,'model':'PP-OCRv4 same files',
          'mediaMs':60000,'order':'ABBA','records':records}));
    } finally {await center.shutdown(); library.dispose();AppStorageService.instance=previousStorage;
      await root.delete(recursive:true);}
  },timeout:const Timeout(Duration(minutes:12)));
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
