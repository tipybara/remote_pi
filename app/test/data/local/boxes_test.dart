// Plan-61 Fase 0 — the local-store key must be encoding-stable.
//
// `LocalBoxes.msgsBoxName` already normalised the epk (it had to: `/` and
// `=` are illegal in a filename). `sessionKey` did not, so a session whose
// epk reached the writer in standard base64 owned a DIFFERENT index /
// runtime row than the same session addressed with the url-safe form —
// two rows, two disagreeing projections of one chat.

import 'package:app/data/local/boxes.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Same 32 bytes in the two encodings the app juggles.
  const urlSafe = 'v_7-_f78-_r5-Pf29fTz8vHw7-7t7Ovq6ejn5uXk4-I';
  final standard = toStandardB64(urlSafe);

  test('fixture sanity: the encodings really differ', () {
    expect(standard, isNot(urlSafe));
  });

  test('sessionKey is the same for both epk encodings', () {
    expect(
      LocalBoxes.sessionKey(standard, 'r1'),
      LocalBoxes.sessionKey(urlSafe, 'r1'),
    );
  });

  test('sessionKey keeps the url-safe form — existing rows stay addressable', () {
    expect(LocalBoxes.sessionKey(urlSafe, 'r1'), '$urlSafe:r1');
  });

  test('sessionKey still separates rooms', () {
    expect(
      LocalBoxes.sessionKey(urlSafe, 'r1'),
      isNot(LocalBoxes.sessionKey(urlSafe, 'r2')),
    );
  });

  test('sessionKey and msgsBoxName agree on the epk form', () {
    expect(
      LocalBoxes.sessionKey(standard, 'r1').split(':').first,
      LocalBoxes.msgsBoxName(standard, 'r1')
          .substring('msgs_'.length)
          .split('__')
          .first,
    );
  });
}
