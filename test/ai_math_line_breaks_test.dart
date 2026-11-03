import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_math_line_breaks.dart';

void main() {
  test('balances a short tail without introducing an extra line', () {
    expect(
      planAiMathLines(
        widths: List.filled(7, 20),
        penalties: List.filled(7, 80),
        maxWidth: 100,
        indent: 10,
      ),
      [0, 4],
    );
  });

  test('uses a relation instead of splitting a product when both fit', () {
    expect(
      planAiMathLines(
        widths: [30, 30, 30, 30],
        penalties: [0, 300, 300, 0],
        maxWidth: 100,
        indent: 0,
      ),
      [0, 3],
    );
  });

  test('preserves a single fitting line and drops unnecessary indentation', () {
    expect(
      planAiMathLines(
        widths: [40, 60],
        penalties: [0, 80],
        maxWidth: 100,
        indent: 18,
      ),
      [0],
    );
    expect(
      planAiMathLines(
        widths: [80, 90],
        penalties: [0, 80],
        maxWidth: 100,
        indent: 18,
      ),
      [0, 1],
    );
  });

  test('isolates an oversized term so other lines can still wrap', () {
    expect(
      planAiMathLines(
        widths: [50, 300, 40, 30],
        penalties: [0, 0, 80, 80],
        maxWidth: 100,
        indent: 10,
      ),
      [0, 1, 2],
    );
  });

  test(
    'independent equations start at the margin instead of a continuation indent',
    () {
      expect(
        planAiMathLines(
          widths: [60, 55, 40],
          penalties: [0, -100, 80],
          maxWidth: 100,
          indent: 20,
        ),
        [0, 1],
      );
    },
  );
}
