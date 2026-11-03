import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/listener_aware_value_notifier.dart';

void main() {
  test('only first and last registrations report demand changes', () {
    var changes = 0;
    var notifications = 0;
    final notifier = ListenerAwareValueNotifier(
      0,
      onListenersChanged: () => changes++,
    );
    addTearDown(notifier.dispose);
    void listener() => notifications++;
    notifier.addListener(listener);
    notifier.addListener(listener);
    expect(changes, 1);
    expect(notifications, 0);
    notifier.removeListener(listener);
    expect(notifier.hasActiveListeners, isTrue);
    expect(changes, 1);
    notifier.removeListener(listener);
    expect(notifier.hasActiveListeners, isFalse);
    expect(changes, 2);
    notifier.removeListener(listener);
    expect(changes, 2);
  });

  test(
    'the last listener removing itself stops demand during notification',
    () {
      var changes = 0;
      final notifier = ListenerAwareValueNotifier(
        0,
        onListenersChanged: () => changes++,
      );
      addTearDown(notifier.dispose);
      void listener() => notifier.removeListener(listener);
      notifier.addListener(listener);
      notifier.value = 1;
      expect(notifier.hasActiveListeners, isFalse);
      expect(changes, 2);
    },
  );
}
