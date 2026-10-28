import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/accounts_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  setUpAll(() => AppTranslation.translations = {});
  testWidgets('thrown login error stops spinner and allows retry',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(
        MaterialApp(home: AccountLoginPage(login: (user, password) async {
      calls++;
      throw StateError('Synthetic failure');
    })));
    await tester.enterText(find.byType(TextField).first, 'sample');
    await tester.enterText(find.byType(TextField).last, 'dummy');
    final button = find.byType(Button);
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<Button>(button).isLoading, isFalse);
    expect(tester.takeException(), isNull);
    await tester.tap(button);
    await tester.pump();
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
      'pending login ignores repeat submit and safely handles leaving page',
      (tester) async {
    final result = Completer<Res<bool>>();
    var calls = 0;
    await tester
        .pumpWidget(MaterialApp(home: AccountLoginPage(login: (user, password) {
      calls++;
      return result.future;
    })));
    await tester.enterText(find.byType(TextField).first, 'sample');
    await tester.enterText(find.byType(TextField).last, 'dummy');
    await tester.tap(find.byType(Button));
    await tester.pump();
    expect(tester.widget<Button>(find.byType(Button)).isLoading, isTrue);
    tester.widget<TextField>(find.byType(TextField).last).onSubmitted!('dummy');
    expect(calls, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    result.complete(const Res.error('Synthetic timeout'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
