import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';

void main() {
  GongyiAsrException classify(int status, Object? body, {String? retryAfter}) {
    final options = RequestOptions(path: '/task/result');
    return GongyiAsrService.classifyDioException(
      DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: options,
          statusCode: status,
          data: body,
          headers: Headers.fromMap({
            if (retryAfter != null) 'retry-after': [retryAfter],
          }),
        ),
      ),
    );
  }

  for (final body in [
    null,
    'Precondition Failed',
    {'message': '请求校验失败'},
    {'message': '未触发风控'},
    {'message': 'not rate limited'},
  ]) {
    test(
      'unexplained 412 is not called frequency or security control: $body',
      () {
        final error = classify(412, body);
        expect(error.kind, GongyiAsrFailureKind.requestRejected);
        expect(error.isRateLimited, isFalse);
        expect(error.isRiskControl, isFalse);
        expect(error.message, contains('原因尚未确认'));
        expect(error.diagnosticSummary, contains('HTTP 412'));
      },
    );
  }

  test(
    'explicit security rejection is distinct from confirmed frequency limits',
    () {
      final security = classify(412, {'message': '由于触发安全风控策略，该次访问请求被拒绝'});
      expect(security.isRiskControl, isTrue);
      expect(security.isRateLimited, isFalse);
      expect(security.message, contains('安全拦截'));
      final limited = classify(429, {
        'message': 'Too Many Requests',
      }, retryAfter: '45');
      expect(limited.isRateLimited, isTrue);
      expect(limited.retryAfter, const Duration(seconds: 45));
    },
  );

  test(
    'a server failure mentioning a risk service is not mistaken for a block',
    () {
      final failure = classify(503, {'message': '风控服务暂时不可用'}, retryAfter: '20');
      expect(failure.kind, GongyiAsrFailureKind.transient);
      expect(failure.isRiskControl, isFalse);
      expect(failure.retryAfter, const Duration(seconds: 20));
    },
  );

  test(
    'an explicit length error in a 412 response can still trigger shorter slices',
    () {
      final error = classify(412, {'message': '音频时长超过限制'});
      expect(error.kind, GongyiAsrFailureKind.tooLong);
      expect(error.suggestsSegmentation, isTrue);
    },
  );

  test('HTML errors retain evidence without scripts, links or credentials', () {
    final error = classify(
      412,
      '<h1>Precondition Failed</h1><script>secret-script-value</script>'
      '<p>SESSDATA=secret-cookie https://host.test/path?token=private</p>',
    );
    expect(error.serverMessage, contains('Precondition Failed'));
    expect(error.serverMessage, isNot(contains('secret-script-value')));
    expect(error.serverMessage, isNot(contains('secret-cookie')));
    expect(error.serverMessage, isNot(contains('private')));
  });

  test(
    'response data does not turn an unrelated transcript into a risk error',
    () {
      final error = classify(500, {
        'message': '存储异常',
        'data': {'transcript': '风控拦截'},
      });
      expect(error.kind, GongyiAsrFailureKind.transient);
    },
  );

  test('a local error message is not treated as server security evidence', () {
    final error = GongyiAsrService.classifyDioException(
      DioException(
        requestOptions: RequestOptions(path: '/task/result'),
        type: DioExceptionType.connectionError,
        message: '代理风控拦截检测失败',
      ),
    );
    expect(error.kind, GongyiAsrFailureKind.networkUnavailable);
  });

  test(
    'Retry-After accepts seconds and HTTP dates and ignores invalid hints',
    () {
      final now = DateTime.utc(2026, 10, 18, 0, 0, 0);
      expect(
        GongyiAsrService.parseRetryAfter('20'),
        const Duration(seconds: 20),
      );
      expect(
        GongyiAsrService.parseRetryAfter(
          HttpDate.format(now.add(const Duration(seconds: 40))),
          now: now,
        ),
        const Duration(seconds: 40),
      );
      expect(
        GongyiAsrService.parseRetryAfter(
          HttpDate.format(now.subtract(const Duration(seconds: 40))),
          now: now,
        ),
        Duration.zero,
      );
      expect(GongyiAsrService.parseRetryAfter('-1'), isNull);
      expect(GongyiAsrService.parseRetryAfter('invalid'), isNull);
    },
  );

  test('query failure metadata survives checkpoint restoration', () async {
    final checkpoint = GongyiAsrTaskCheckpoint(taskId: 'submitted-task');
    await checkpoint.recordQueryFailure(
      classify(412, {'code': -412, 'message': '请求校验失败'}),
    );
    final restored = GongyiAsrTaskCheckpoint.fromJson(checkpoint.toJson());
    expect(restored.taskId, 'submitted-task');
    expect(restored.lastQueryFailure?['httpStatus'], 412);
    expect(restored.lastQueryFailure?['apiCode'], -412);
    expect(restored.lastQueryFailure?['serverMessage'], '请求校验失败');
    expect(restored.lastQueryFailure?['endpoint'], '/task/result');
  });

  test('definitive task errors still decode errors inside result JSON', () {
    final error = GongyiAsrService.classifyTaskPayload({
      'state': 5,
      'result': '{"message":"音频时长超过限制"}',
    });
    expect(error.kind, GongyiAsrFailureKind.tooLong);
  });
}
