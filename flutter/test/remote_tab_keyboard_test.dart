import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

class _Binding extends Fake implements RustdeskImpl {
  @override
  bool isIncomingOnly({dynamic hint}) => false;

  @override
  bool isOutgoingOnly({dynamic hint}) => false;
}

void main() {
  testWidgets('reopening a kept-alive tab binds the visible page after pausing',
      (tester) async {
    platformFFI.setBindingForTesting(_Binding());
    final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
    final tabA = TabInfo(key: 'a', label: 'A', page: const Text('A'));
    final tabB = TabInfo(key: 'b', label: 'B', page: const Text('B'));
    final bindings = <String?>[];
    Completer<void>? pause;
    tabs.onKeyboardPageChanged = (key) async {
      if (key == null) await pause?.future;
      bindings.add(key);
    };

    tabs.add(tabA);
    await tester.pumpWidget(MaterialApp(
      home: Obx(() => PageView(
        controller: tabs.state.value.pageController,
        children: tabs.state.value.tabs.map((tab) => tab.page).toList(),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    tabs.add(tabB);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tabs.state.value.pageController.page, 1);

    bindings.clear();
    pause = Completer<void>();
    tabs.add(tabA);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tabs.state.value.pageController.page, 1);
    expect(bindings, isEmpty);
    pause.complete();
    await tester.pumpAndSettle();
    expect(tabs.state.value.pageController.page, 0);
    expect(bindings, [null, 'a']);
  });
}
