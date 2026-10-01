// Right to left: the user's bubbles sit at the left, the replies at the right, the action bar starts at the right.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('${direction.name}: bubbles, replies and chips follow the direction', (tester) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(
        app(
          Directionality(
            textDirection: direction,
            child: ChatPage(controller: controller, assistantName: 'Acme', suggestions: const ['Orders?']),
          ),
        ),
      );
      final width = tester.getSize(find.byType(Scaffold)).width;
      final chip = tester.getRect(find.byKey(LocalInferenceKeys.suggestion(0)));
      engine.outputs.add('Fine.');
      await sendText(tester, controller, 'hello');
      final user = tester.getRect(find.byKey(LocalInferenceKeys.message(1)));
      final reply = tester.getRect(find.byKey(LocalInferenceKeys.message(2)));
      final rtl = direction == TextDirection.rtl;
      // The list's padding is 12 on each side.
      expect(rtl ? user.left : width - user.right, moreOrLessEquals(12, epsilon: 1), reason: 'the user at the end');
      expect(
        rtl ? width - reply.right : reply.left,
        moreOrLessEquals(12, epsilon: 1),
        reason: 'the reply at the start',
      );
      expect(rtl ? width - chip.right : chip.left, moreOrLessEquals(12, epsilon: 1), reason: 'the chips at the start');
      expect(tester.takeException(), isNull);
    });
  }
}
