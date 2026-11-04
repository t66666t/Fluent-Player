import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';

void main() {
  group('Bilibili login status classification', () {
    test('recognizes an explicitly logged-in response', () {
      final status = BilibiliApiService.classifyLoginResponse(
        statusCode: 200,
        responseData: {
          'code': 0,
          'data': {'isLogin': true},
        },
      );

      expect(status, BilibiliLoginStatus.loggedIn);
    });

    test('isLogin false with a cookie means the login expired', () {
      final status = BilibiliApiService.classifyLoginResponse(
        statusCode: 200,
        responseData: {
          'code': 0,
          'data': {'isLogin': false},
        },
      );

      expect(status, BilibiliLoginStatus.expired);
    });

    test('code -101 means the login expired', () {
      expect(
        BilibiliApiService.classifyLoginResponse(
          statusCode: 200,
          responseData: {'code': -101, 'message': '账号未登录'},
        ),
        BilibiliLoginStatus.expired,
      );
    });

    test('does not misclassify an unavailable response as expired', () {
      expect(
        BilibiliApiService.classifyLoginResponse(
          statusCode: null,
          responseData: null,
        ),
        BilibiliLoginStatus.networkError,
      );
      expect(
        BilibiliApiService.classifyLoginResponse(
          statusCode: 200,
          responseData: {'code': -1},
        ),
        BilibiliLoginStatus.networkError,
      );
      expect(
        BilibiliApiService.classifyLoginResponse(
          statusCode: 412,
          responseData: {'code': -412},
        ),
        BilibiliLoginStatus.networkError,
      );
      expect(
        BilibiliApiService.classifyLoginResponse(
          statusCode: 200,
          responseData: '<html>blocked</html>',
        ),
        BilibiliLoginStatus.networkError,
      );
    });

    test('parses account info and normalizes the avatar to https', () {
      final state = BilibiliApiService.parseNavResponse(
        statusCode: 200,
        responseData:
            '{"code":0,"data":{"isLogin":true,"mid":42,"uname":"tester",'
            '"face":"http://i0.hdslb.com/bfs/face/a.jpg"}}',
      );
      expect(state.status, BilibiliLoginStatus.loggedIn);
      expect(state.account?.mid, 42);
      expect(state.account?.name, 'tester');
      expect(state.account?.avatarUrl, 'https://i0.hdslb.com/bfs/face/a.jpg');
    });
  });
}
