import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/ui_interaction_budget.dart';

void main() {
  test(
    'nested surfaces and pointer-up to locate keep one uninterrupted budget',
    () async {
      final budget = UiInteractionBudget();
      final changes = <bool>[];
      budget.addListener(() => changes.add(budget.isActive));
      final first = budget.acquire();
      final second = budget.acquire();
      first();
      first();
      await Future<void>.value();
      expect(changes, [true]);
      second();
      final locate = budget.acquire();
      await Future<void>.value();
      expect(changes, [true]);
      locate();
      await Future<void>.value();
      expect(changes, [true, false]);
      budget.dispose();
    },
  );
}
