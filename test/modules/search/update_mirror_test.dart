import 'package:flutter_test/flutter_test.dart';
import 'package:moviepilot_mobile/modules/search/models/update_mirror.dart';

void main() {
  const source = 'https://github.com/o/r/releases/download/v1/app.apk';

  group('UpdateMirror.resolve', () {
    test('direct returns the source url untouched', () {
      expect(const UpdateMirror.direct().resolve(source), source);
    });

    test('prefix template joins with a trailing slash', () {
      const mirror = UpdateMirror(
        id: 'p',
        label: 'p',
        template: 'https://ghproxy.net/',
      );
      expect(mirror.resolve(source), 'https://ghproxy.net/$source');
    });

    test('prefix template without trailing slash still joins correctly', () {
      const mirror = UpdateMirror(
        id: 'p',
        label: 'p',
        template: 'https://ghproxy.net',
      );
      expect(mirror.resolve(source), 'https://ghproxy.net/$source');
    });

    test('placeholder template substitutes {url}', () {
      const mirror = UpdateMirror(
        id: 'q',
        label: 'q',
        template: 'https://x.dev/fetch?u={url}&flag=1',
      );
      expect(
        mirror.resolve(source),
        'https://x.dev/fetch?u=https://github.com/o/r/releases/download/v1/app.apk&flag=1',
      );
    });
  });

  group('UpdateMirror.validateTemplate', () {
    test('rejects empty input', () {
      expect(UpdateMirror.validateTemplate('   '), isNotNull);
    });

    test('rejects non http schemes', () {
      expect(UpdateMirror.validateTemplate('ftp://example.com/'), isNotNull);
    });

    test('rejects a bare host without slash or placeholder', () {
      expect(UpdateMirror.validateTemplate('https://example.com'), isNotNull);
    });

    test('accepts prefix style with trailing slash', () {
      expect(UpdateMirror.validateTemplate('https://example.com/'), isNull);
    });

    test('accepts prefix style with a path', () {
      expect(
        UpdateMirror.validateTemplate('https://example.com/gh'),
        isNull,
      );
    });

    test('accepts placeholder style', () {
      expect(
        UpdateMirror.validateTemplate('https://example.com/{url}'),
        isNull,
      );
    });
  });

  group('UpdateMirror.labelFromTemplate', () {
    test('uses the host as the label', () {
      expect(
        UpdateMirror.labelFromTemplate('https://ghproxy.net/'),
        'ghproxy.net',
      );
    });

    test('works with a placeholder template', () {
      expect(
        UpdateMirror.labelFromTemplate('https://mirror.dev/{url}'),
        'mirror.dev',
      );
    });
  });

  test('fromJson drops malformed entries and defaults the label', () {
    expect(UpdateMirror.fromJson('nope'), isNull);
    expect(UpdateMirror.fromJson({'id': '', 'template': 'x'}), isNull);
    final parsed = UpdateMirror.fromJson({
      'id': 'c1',
      'template': 'https://mirror.dev/',
    });
    expect(parsed?.label, 'mirror.dev');
    expect(parsed?.builtin, isFalse);
  });
}
