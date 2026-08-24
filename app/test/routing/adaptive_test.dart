// Plan/tablet — adaptive master-detail shell.
//
// Verifies the three moving parts without spinning up the full DI/boot:
//   1. SessionSelection notifier semantics (select / matches / clear / no-op).
//   2. isWideLayout breakpoint.
//   3. The StatefulShellRoute + navigatorContainerBuilder layout decision:
//      wide → master + detail side by side; narrow → only the active branch.

import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/routing/adaptive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

GoRouter _buildAdaptiveRouter() {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      StatefulShellRoute(
        builder: (ctx, st, navShell) => navShell,
        navigatorContainerBuilder: (ctx, navShell, children) {
          if (!isWideLayout(ctx)) return children[navShell.currentIndex];
          return Row(
            children: [
              SizedBox(width: 360, child: children[0]),
              Expanded(child: children[1]),
            ],
          );
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                builder: (_, _) =>
                    const Scaffold(body: Center(child: Text('MASTER'))),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/session',
                builder: (_, _) =>
                    const Scaffold(body: Center(child: Text('DETAIL'))),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp.router(routerConfig: _buildAdaptiveRouter()),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('SessionSelection', () {
    test('starts empty (no pre-selection on launch)', () {
      final sel = SessionSelection();
      expect(sel.current, isNull);
      expect(sel.matches('epk', 'main'), isFalse);
    });

    test('select sets current and matches the (epk, room)', () {
      final sel = SessionSelection();
      var notifications = 0;
      sel.addListener(() => notifications++);

      sel.select('epkA', 'main', 'Title A');
      expect(sel.current?.epk, 'epkA');
      expect(sel.current?.roomId, 'main');
      expect(sel.current?.title, 'Title A');
      expect(sel.matches('epkA', 'main'), isTrue);
      expect(sel.matches('epkA', 'other'), isFalse);
      expect(sel.matches('epkB', 'main'), isFalse);
      expect(notifications, 1);
    });

    test('re-selecting the same session is a no-op (no rebuild)', () {
      final sel = SessionSelection();
      sel.select('epkA', 'main', 'Title A');
      var notifications = 0;
      sel.addListener(() => notifications++);

      sel.select('epkA', 'main', 'Title A again');
      expect(notifications, 0, reason: 'same (epk, room) must not notify');
      expect(sel.current?.title, 'Title A', reason: 'unchanged');
    });

    test(
      'plan-61 fase 0 — matches/select normalise the epk: the url-safe form '
      '(PeerRecord / QR) and the standard form (relay) are the SAME session',
      () {
        // Same 32 bytes, the two encodings the app juggles.
        const urlSafe = 'v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I';
        final standard = toStandardB64(urlSafe);
        expect(standard, isNot(urlSafe), reason: 'fixture must be meaningful');

        final sel = SessionSelection();
        sel.select(urlSafe, 'r1', 'Chat');

        expect(sel.matches(standard, 'r1'), isTrue,
            reason: 'the relay reports the standard form for this machine');
        expect(sel.matches(urlSafe, 'r1'), isTrue);
        expect(sel.matches(standard, 'r2'), isFalse);

        // The stable key used to key the tablet detail pane.
        expect(sel.sessionKey, '$standard|r1');

        // Re-selecting the same session in the other encoding is a no-op.
        var notifications = 0;
        sel.addListener(() => notifications++);
        sel.select(standard, 'r1', 'Chat again');
        expect(notifications, 0);
      },
    );

    test('sessionKey is null while nothing is selected', () {
      expect(SessionSelection().sessionKey, isNull);
    });

    test('clear resets to empty and notifies once', () {
      final sel = SessionSelection();
      sel.select('epkA', 'main', 'Title A');
      var notifications = 0;
      sel.addListener(() => notifications++);

      sel.clear();
      expect(sel.current, isNull);
      expect(notifications, 1);
      sel.clear(); // already empty
      expect(notifications, 1, reason: 'clearing twice must not re-notify');
    });
  });

  group('isWideLayout — device class by shortestSide (rotation-invariant)', () {
    Future<bool> wideAt(WidgetTester tester, Size size) async {
      late bool wide;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (ctx) {
              wide = isWideLayout(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      return wide;
    }

    testWidgets(
      'phone landscape stays phone (regression: width>=600 but height<600)',
      (tester) async {
        expect(await wideAt(tester, const Size(932, 430)), isFalse);
      },
    );

    testWidgets('phone portrait is phone', (tester) async {
      expect(await wideAt(tester, const Size(420, 900)), isFalse);
    });

    testWidgets('iPad portrait is tablet', (tester) async {
      expect(await wideAt(tester, const Size(768, 1024)), isTrue);
    });

    testWidgets('iPad landscape is tablet', (tester) async {
      expect(await wideAt(tester, const Size(1024, 768)), isTrue);
    });

    testWidgets('narrow Split View window collapses to phone', (tester) async {
      expect(await wideAt(tester, const Size(400, 1000)), isFalse);
    });

    testWidgets('breakpoint needs BOTH sides >= 600', (tester) async {
      expect(await wideAt(tester, const Size(600, 600)), isTrue);
      expect(
        await wideAt(tester, const Size(599, 1200)),
        isFalse,
        reason: 'one side below 600 → phone',
      );
    });
  });

  group('adaptive shell layout', () {
    testWidgets('tablet (both sides >= 600) → master AND detail', (
      tester,
    ) async {
      await _pumpAt(tester, const Size(1024, 768)); // iPad landscape
      expect(find.text('MASTER'), findsOneWidget);
      expect(find.text('DETAIL'), findsOneWidget);
    });

    testWidgets('phone portrait → only the active branch (master)', (
      tester,
    ) async {
      await _pumpAt(tester, const Size(420, 900));
      expect(find.text('MASTER'), findsOneWidget);
      expect(find.text('DETAIL'), findsNothing);
    });

    testWidgets(
      'phone landscape → only master (regression: width 932 >= 600 but it is a '
      'phone, so no two-pane)',
      (tester) async {
        await _pumpAt(tester, const Size(932, 430));
        expect(find.text('MASTER'), findsOneWidget);
        expect(find.text('DETAIL'), findsNothing);
      },
    );
  });

  group('zero-state collapse', () {
    GoRouter buildGatedRouter() {
      return GoRouter(
        initialLocation: '/home',
        routes: [
          StatefulShellRoute(
            builder: (ctx, st, navShell) => navShell,
            navigatorContainerBuilder: (ctx, navShell, children) {
              final twoPane =
                  isWideLayout(ctx) && !ctx.watch<ShellLayout>().isZeroState;
              if (!twoPane) return children[navShell.currentIndex];
              return Row(
                children: [
                  SizedBox(width: 360, child: children[0]),
                  Expanded(child: children[1]),
                ],
              );
            },
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/home',
                    builder: (_, _) =>
                        const Scaffold(body: Center(child: Text('MASTER'))),
                  ),
                ],
              ),
              StatefulShellBranch(
                preload: true,
                routes: [
                  GoRoute(
                    path: '/session',
                    builder: (_, _) =>
                        const Scaffold(body: Center(child: Text('DETAIL'))),
                  ),
                ],
              ),
            ],
          ),
        ],
      );
    }

    testWidgets(
      'wide + zero-state shows only master; flipping back re-splits',
      (tester) async {
        final shell = ShellLayout()..setZeroState(true);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1200, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          ChangeNotifierProvider<ShellLayout>.value(
            value: shell,
            child: MaterialApp.router(routerConfig: buildGatedRouter()),
          ),
        );
        await tester.pumpAndSettle();

        // Zero-state on a wide screen → single pane (no split).
        expect(find.text('MASTER'), findsOneWidget);
        expect(find.text('DETAIL'), findsNothing);

        // Sessions appear → the split returns.
        shell.setZeroState(false);
        await tester.pumpAndSettle();
        expect(find.text('MASTER'), findsOneWidget);
        expect(find.text('DETAIL'), findsOneWidget);
      },
    );
  });

  group('two-pane SafeArea insets (side insets beside the divider)', () {
    // Mirrors app_router's navigatorContainerBuilder two-pane Row. Each pane is
    // a Scaffold whose body is wrapped in SafeArea (like HomePage / ChatPage).
    // The regression: each pane's SafeArea reads the *full screen* padding, so
    // it also insets the edge facing the divider — a phantom horizontal gutter.
    // The fix strips the divider-facing inset per pane via MediaQuery.removePadding.
    //
    // Uses a tablet-class window (both sides >= 600) since two-pane is now
    // gated on shortestSide — a phone in landscape no longer reaches here.
    const masterKey = Key('master-body');
    const detailKey = Key('detail-body');
    const screen = Size(1024, 768); // iPad landscape
    const padLeft = 60.0; // inset side (e.g. camera housing / rounded corner)
    const padRight = 30.0; // opposite-edge inset
    const padTop = 12.0;
    const padBottom = 21.0; // home indicator
    const dividerW = 1.0;

    Widget pane(Key k) => Scaffold(
      body: SafeArea(child: SizedBox.expand(key: k)),
    );

    Widget twoPaneRow({required bool withFix}) {
      Widget left = SizedBox(width: 360, child: pane(masterKey));
      Widget right = Expanded(child: pane(detailKey));
      if (withFix) {
        left = SizedBox(
          width: 360,
          child: Builder(
            builder: (ctx) => MediaQuery.removePadding(
              context: ctx,
              removeRight: true,
              child: pane(masterKey),
            ),
          ),
        );
        right = Expanded(
          child: Builder(
            builder: (ctx) => MediaQuery.removePadding(
              context: ctx,
              removeLeft: true,
              child: pane(detailKey),
            ),
          ),
        );
      }
      return Row(
        children: [
          left,
          const VerticalDivider(width: dividerW),
          right,
        ],
      );
    }

    Future<void> pumpRow(WidgetTester tester, {required bool withFix}) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = screen;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: screen,
              padding: EdgeInsets.fromLTRB(
                padLeft,
                padTop,
                padRight,
                padBottom,
              ),
            ),
            child: twoPaneRow(withFix: withFix),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('without the fix: phantom gutter beside the divider', (
      tester,
    ) async {
      await pumpRow(tester, withFix: false);
      // Master (left pane) wrongly insets its right → stops short of the divider.
      expect(tester.getRect(find.byKey(masterKey)).right, 360 - padRight);
      // Detail (right pane) wrongly insets its left → gap after the divider.
      expect(
        tester.getRect(find.byKey(detailKey)).left,
        360 + dividerW + padLeft,
      );
    });

    testWidgets(
      'with the fix: content reaches the divider, outer insets kept',
      (tester) async {
        await pumpRow(tester, withFix: true);
        final master = tester.getRect(find.byKey(masterKey));
        final detail = tester.getRect(find.byKey(detailKey));

        // Divider-facing edges now reach the divider (no phantom gutter).
        expect(master.right, 360, reason: 'master fills up to the divider');
        expect(
          detail.left,
          360 + dividerW,
          reason: 'detail starts at the divider',
        );

        // Outer screen-edge + top/bottom insets are still honored (surgical).
        expect(master.left, padLeft, reason: 'screen left inset preserved');
        expect(
          detail.right,
          screen.width - padRight,
          reason: 'screen right inset preserved',
        );
        for (final r in [master, detail]) {
          expect(r.top, padTop, reason: 'top inset preserved');
          expect(
            r.bottom,
            screen.height - padBottom,
            reason: 'bottom inset preserved',
          );
        }
      },
    );
  });
}
