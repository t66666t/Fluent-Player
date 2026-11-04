import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_quality_outcome.dart';
import 'package:video_player_app/services/media_playback_service.dart';

CloudDriveQualityChoice rung(
  String id, {
  CloudDriveQualityAvailability availability =
      CloudDriveQualityAvailability.available,
  bool complete = true,
  String? statusDetail,
}) {
  return CloudDriveQualityChoice(
    id: id,
    label: id,
    transcoded: id != 'original',
    complete: complete,
    availability: availability,
    statusDetail: statusDetail,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('outcome classification', () {
    CloudDriveQualitySwitchOutcome outcome(
      CloudDriveQualitySwitchResult result,
    ) {
      return CloudDriveQualitySwitchOutcome(
        operationId: 'q1',
        requestedQualityId: '1080p',
        stage: CloudDriveQualitySwitchStage.initialize,
        result: result,
      );
    }

    test('only a real failure is presented as a switch failure', () {
      expect(
        outcome(CloudDriveQualitySwitchResult.failed).showFailure,
        isTrue,
      );
      for (final result in <CloudDriveQualitySwitchResult>[
        CloudDriveQualitySwitchResult.committed,
        CloudDriveQualitySwitchResult.alreadySelected,
        CloudDriveQualitySwitchResult.notReady,
        CloudDriveQualitySwitchResult.unavailable,
        CloudDriveQualitySwitchResult.cancelled,
        CloudDriveQualitySwitchResult.superseded,
      ]) {
        expect(outcome(result).showFailure, isFalse, reason: result.name);
      }
      // A newer selection must not pop a toast at all.
      expect(outcome(CloudDriveQualitySwitchResult.superseded).message, isNull);
      expect(
        outcome(CloudDriveQualitySwitchResult.notReady).message,
        contains('准备'),
      );
    });

    test('reasons are redacted before they reach a log or the UI', () {
      final reason = sanitizeCloudDriveQualityReason(
        const CloudDriveFailure(
          CloudDriveFailureKind.notLoggedIn,
          'BDUSS=secret-token https://pan.baidu.com/a.srt?sign=abc 需要重新登录',
        ),
      );
      expect(reason, isNot(contains('secret-token')));
      expect(reason, isNot(contains('sign=abc')));
      expect(reason, contains('需要重新登录'));
    });

    test('the diagnostic line names the stage and the operation', () {
      final line = CloudDriveQualitySwitchOutcome(
        operationId: 'q7',
        requestedQualityId: '1080p',
        actualQualityId: '720p',
        stage: CloudDriveQualitySwitchStage.handoff,
        result: CloudDriveQualitySwitchResult.failed,
        errorType: 'TimeoutException',
        elapsedMs: 6100,
        retryable: true,
        reason: '画质切换超时',
      ).toDiagnosticLine();
      expect(line, contains('quality=q7'));
      expect(line, contains('stage=handoff'));
      expect(line, contains('result=failed'));
      expect(line, contains('requested=1080p'));
      expect(line, contains('actual=720p'));
      expect(line, contains('retryable=1'));
    });
  });

  group('switch entry guards', () {
    late MediaPlaybackService service;

    setUp(() {
      service = MediaPlaybackService.forTesting();
    });

    tearDown(() {
      service.debugSeedCurrentItem(null);
      service.debugSeedCloudDriveQualities(const []);
    });

    test('no current media is not ready, not a failed switch', () async {
      final outcome = await service.switchCloudDriveQualityOutcome('1080p');
      expect(outcome.result, CloudDriveQualitySwitchResult.notReady);
      expect(outcome.stage, CloudDriveQualitySwitchStage.entry);
      expect(outcome.showFailure, isFalse);
      expect(outcome.retryable, isTrue);
      expect(await service.switchCloudDriveQuality('1080p'), isFalse);
    });

    test('an unavailable rung reports its own status and starts no switch',
        () async {
      service.debugSeedCloudDriveQualities([
        rung('original'),
        rung(
          '1080p',
          availability: CloudDriveQualityAvailability.unavailable,
          statusDetail: '当前账号不可用',
        ),
      ], selectedId: 'original');
      final outcome = await service.switchCloudDriveQualityOutcome('1080p');
      expect(outcome.result, CloudDriveQualitySwitchResult.unavailable);
      expect(outcome.message, '当前账号不可用');
      expect(service.cloudDriveNotice, '当前账号不可用');
    });

    test('a rung that is still being probed is not ready', () async {
      service.debugSeedCloudDriveQualities([
        rung('original'),
        rung(
          '1080p',
          availability: CloudDriveQualityAvailability.discovering,
          complete: false,
          statusDetail: '正在检测',
        ),
      ], selectedId: 'original');
      final outcome = await service.switchCloudDriveQualityOutcome('1080p');
      expect(outcome.result, CloudDriveQualitySwitchResult.notReady);
      expect(outcome.showFailure, isFalse);
    });

    test('choosing the current rung succeeds without a request', () async {
      service.debugSeedCloudDriveQualities([
        rung('original'),
        rung('1080p'),
      ], selectedId: '1080p');
      final outcome = await service.switchCloudDriveQualityOutcome('1080p');
      expect(outcome.result, CloudDriveQualitySwitchResult.alreadySelected);
      expect(outcome.succeeded, isTrue);
      expect(await service.switchCloudDriveQuality('1080p'), isTrue);
    });

    test('the copied diagnostic carries the build identity and last outcome',
        () async {
      service.debugSeedCloudDriveQualities([rung('original')],
          selectedId: 'original');
      await service.switchCloudDriveQualityOutcome('1080p');
      final report = service.cloudDriveDiagnosticReport;
      expect(report, isNotNull);
      expect(report, contains('build='));
      expect(report, contains('result=notReady'));
    });
  });
}
