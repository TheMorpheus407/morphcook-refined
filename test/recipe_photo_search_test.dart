import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/logic/import/recipe_photo_search.dart';
import 'package:morphcook/logic/sharing/recipe_share.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/recipe_image.dart';

import 'helpers.dart';

bool _commonsHosts(Uri uri) =>
    uri.scheme == 'https' && defaultRecipePhotoHosts.contains(uri.host);

Map<String, dynamic> _page({
  required int index,
  required String title,
  String mime = 'image/jpeg',
  String? thumb,
  String? source,
  String? artist = '<a href="//commons.wikimedia.org/wiki/User:A">Ann</a>',
  String? license = 'CC BY-SA 4.0',
  String? objectName,
}) => {
  'title': 'File:$title',
  'index': index,
  'imageinfo': [
    {
      'thumburl':
          thumb ??
          'https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ab/$title/960px-$title?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=thumbnail',
      'url': 'https://upload.wikimedia.org/wikipedia/commons/a/ab/$title',
      'descriptionurl':
          source ?? 'https://commons.wikimedia.org/wiki/File:$title',
      'mime': mime,
      'extmetadata': {
        if (artist != null) 'Artist': {'value': artist},
        if (license != null) 'LicenseShortName': {'value': license},
        if (objectName != null) 'ObjectName': {'value': objectName},
      },
    },
  ],
};

Future<Uri> _serve(void Function(HttpRequest request) handle) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handle);
  addTearDown(() => server.close(force: true));
  return Uri.parse('http://127.0.0.1:${server.port}/w/api.php');
}

RecipePhotoSearch _localSearch(Uri endpoint, {Duration? timeout}) =>
    RecipePhotoSearch(
      endpoint: endpoint,
      allowedHosts: {endpoint.host},
      timeout: timeout ?? const Duration(seconds: 5),
    );

RecipeImageCredit _credit({String author = 'Ann'}) =>
    RecipeImageCredit.tryCreate(
      title: 'Pad thai mound',
      author: author,
      license: 'CC BY-SA 2.0',
      provider: recipePhotoProvider,
      sourceUrl: 'https://commons.wikimedia.org/wiki/File:Pad_thai_mound.jpg',
    )!;

Future<AppState> _state(MemoryStore store) async {
  final state = AppState(store: store, corpus: await loadRealCorpus());
  await state.load();
  return state;
}

void main() {
  group('Commons response parsing', () {
    test('keeps search ranking, strips HTML and campaign parameters', () {
      final results = parseRecipePhotoSearch({
        'query': {
          'pages': [
            _page(index: 2, title: 'Second.jpg', objectName: 'Second dish'),
            _page(
              index: 1,
              title: 'First.png',
              mime: 'image/png',
              artist: '<b>Bo</b>\n <i>Chef</i>',
            ),
          ],
        },
      }, allowImage: _commonsHosts);

      expect(results.map((r) => r.credit.title), ['First.png', 'Second dish']);
      expect(results.first.credit.author, 'Bo Chef');
      expect(results.last.credit.author, 'Ann');
      expect(results.first.credit.license, 'CC BY-SA 4.0');
      expect(results.first.credit.provider, 'Wikimedia Commons');
      expect(
        results.first.imageUrl.toString(),
        'https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ab/First.png/960px-First.png',
      );
      expect(
        results.first.credit.sourceUrl.toString(),
        'https://commons.wikimedia.org/wiki/File:First.png',
      );
    });

    test('drops results that cannot be credited, stored or safely loaded', () {
      final results = parseRecipePhotoSearch({
        'query': {
          'pages': [
            _page(index: 1, title: 'NoLicense.jpg', license: null),
            _page(index: 2, title: 'Drawing.svg', mime: 'image/svg+xml'),
            _page(index: 3, title: 'Animated.gif', mime: 'image/gif'),
            _page(
              index: 4,
              title: 'Elsewhere.jpg',
              thumb: 'https://tracker.example/Elsewhere.jpg',
            ),
            _page(
              index: 5,
              title: 'Plain.jpg',
              thumb: 'http://upload.wikimedia.org/Plain.jpg',
            ),
            _page(index: 6, title: 'BadSource.jpg', source: 'javascript:x'),
            {'title': 'File:NoInfo.jpg', 'index': 7},
            'not a page',
            _page(index: 8, title: 'Kept.webp', mime: 'image/webp'),
            // The same preview twice is offered once.
            _page(index: 9, title: 'Kept.webp', mime: 'image/webp'),
            _page(index: 10, title: 'Anonymous.jpg', artist: null),
          ],
        },
      }, allowImage: _commonsHosts);

      expect(results.map((r) => r.credit.title), [
        'Kept.webp',
        'Anonymous.jpg',
      ]);
      expect(results.last.credit.author, isNull);
      expect(
        results.last.credit.label('en'),
        'Photo: Anonymous.jpg · CC BY-SA 4.0 · Wikimedia Commons',
      );
    });

    test('an empty search is not an error; malformed responses are', () {
      expect(
        parseRecipePhotoSearch({
          'batchcomplete': true,
        }, allowImage: _commonsHosts),
        isEmpty,
      );
      for (final invalid in <Object?>[
        null,
        <Object?>[],
        {
          'error': {'code': 'maxlag'},
        },
        {'query': 'pages'},
        {
          'query': {'pages': 'x'},
        },
      ]) {
        expect(
          () => parseRecipePhotoSearch(invalid, allowImage: _commonsHosts),
          throwsA(
            isA<RecipePhotoSearchException>().having(
              (e) => e.failure,
              'failure',
              RecipePhotoSearchFailure.invalidResponse,
            ),
          ),
        );
      }
    });

    test('results are capped', () {
      final results = parseRecipePhotoSearch({
        'query': {
          'pages': [
            for (var i = 0; i < 30; i++) _page(index: i, title: 'P$i.jpg'),
          ],
        },
      }, allowImage: _commonsHosts);
      expect(results, hasLength(maxRecipePhotoSearchResults));
      expect(results.first.credit.title, 'P0.jpg');
    });
  });

  group('network requests', () {
    test('a blank query makes no request', () async {
      var requests = 0;
      final endpoint = await _serve((request) {
        requests++;
        request.response.close();
      });
      expect(await _localSearch(endpoint).search('  \n '), isEmpty);
      expect(requests, 0);
    });

    test('sends only the search words with an identifying agent', () async {
      late Uri requested;
      late String? agent;
      late String? cookie;
      final endpoint = await _serve((request) {
        requested = request.uri;
        agent = request.headers.value(HttpHeaders.userAgentHeader);
        cookie = request.headers.value(HttpHeaders.cookieHeader);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'query': {
              'pages': [
                _page(
                  index: 1,
                  title: 'Doener.jpg',
                  thumb:
                      'http://127.0.0.1:${request.connectionInfo!.localPort}/Doener.jpg',
                  source: 'https://commons.wikimedia.org/wiki/File:Doener.jpg',
                ),
              ],
            },
          }),
        );
        request.response.close();
      });

      final results = await _localSearch(
        endpoint,
      ).search('  Döner   kebab ', lang: 'de');

      expect(results.single.credit.title, 'Doener.jpg');
      expect(requested.path, '/w/api.php');
      expect(
        requested.queryParameters['gsrsearch'],
        'Döner kebab filetype:bitmap',
      );
      expect(requested.queryParameters['gsrnamespace'], '6');
      expect(requested.queryParameters['iiextmetadatalanguage'], 'de');
      expect(requested.queryParameters['gsrlimit'], '12');
      expect(agent, contains('MorphCook'));
      expect(agent, contains('github.com/TheMorpheus407/morphcook-refined'));
      expect(cookie, isNull);
    });

    test('long queries are shortened before sending', () {
      expect(
        normalizeRecipePhotoQuery('a' * 300),
        hasLength(maxRecipePhotoQueryLength),
      );
    });

    test('downloads a valid preview and rejects non-images', () async {
      final endpoint = await _serve((request) {
        if (request.uri.path == '/photo.png') {
          request.response.add(testPngBytes());
        } else {
          request.response.write('<html>not an image</html>');
        }
        request.response.close();
      });
      final search = _localSearch(endpoint);
      RecipePhotoCandidate candidate(String path) => RecipePhotoCandidate(
        imageUrl: endpoint.replace(path: path, query: ''),
        credit: _credit(),
      );

      expect(
        await search.download(candidate('/photo.png')),
        orderedEquals(testPngBytes()),
      );
      await expectLater(
        search.download(candidate('/page.html')),
        throwsA(
          isA<RecipePhotoSearchException>().having(
            (e) => e.failure,
            'failure',
            RecipePhotoSearchFailure.unsupportedImage,
          ),
        ),
      );
    });

    test('previews and responses are size bounded', () async {
      final endpoint = await _serve((request) {
        request.response.headers.contentType = ContentType.json;
        request.response.add(List.filled(4096, 32));
        request.response.close();
      });
      final search = RecipePhotoSearch(
        endpoint: endpoint,
        allowedHosts: {endpoint.host},
        maxResponseBytes: 1024,
        maxImageBytes: 1024,
      );
      await expectLater(
        search.search('soup'),
        throwsA(
          isA<RecipePhotoSearchException>().having(
            (e) => e.failure,
            'failure',
            RecipePhotoSearchFailure.tooLarge,
          ),
        ),
      );
      await expectLater(
        search.download(
          RecipePhotoCandidate(
            imageUrl: endpoint.replace(path: '/big.jpg', query: ''),
            credit: _credit(),
          ),
        ),
        throwsA(isA<RecipePhotoSearchException>()),
      );
    });

    test('never follows a redirect away from the provider', () async {
      var outsideRequests = 0;
      final outside = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      outside.listen((request) {
        outsideRequests++;
        request.response.close();
      });
      addTearDown(() => outside.close(force: true));
      final endpoint = await _serve((request) {
        request.response.statusCode = HttpStatus.found;
        // A different host name for the same machine is still another host.
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://localhost:${outside.port}/photo.jpg',
        );
        request.response.close();
      });

      await expectLater(
        _localSearch(endpoint).search('soup'),
        throwsA(
          isA<RecipePhotoSearchException>().having(
            (e) => e.failure,
            'failure',
            RecipePhotoSearchFailure.network,
          ),
        ),
      );
      expect(outsideRequests, 0);
    });

    test('other hosts and schemes are refused before connecting', () async {
      final search = RecipePhotoSearch();
      expect(
        search.isAllowed(Uri.parse('https://upload.wikimedia.org/a.jpg')),
        isTrue,
      );
      expect(
        search.isAllowed(Uri.parse('http://upload.wikimedia.org/a.jpg')),
        isFalse,
      );
      expect(search.isAllowed(Uri.parse('https://example.com/a.jpg')), isFalse);
      await expectLater(
        search.download(
          RecipePhotoCandidate(
            imageUrl: Uri.parse('https://example.com/a.jpg'),
            credit: _credit(),
          ),
        ),
        throwsA(isA<RecipePhotoSearchException>()),
      );
    });

    test('server errors, bad JSON and silence fail cleanly', () async {
      final endpoint = await _serve((request) {
        switch (request.uri.queryParameters['gsrsearch']) {
          case 'error filetype:bitmap':
            request.response.statusCode = HttpStatus.internalServerError;
          case 'busy filetype:bitmap':
            request.response.statusCode = HttpStatus.tooManyRequests;
          case 'html filetype:bitmap':
            request.response.headers.contentType = ContentType.html;
            request.response.write('<html></html>');
          case 'broken filetype:bitmap':
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"query":');
          default:
            // Never answer.
            return;
        }
        request.response.close();
      });
      final search = _localSearch(
        endpoint,
        timeout: const Duration(milliseconds: 300),
      );
      Matcher fails(RecipePhotoSearchFailure failure) => throwsA(
        isA<RecipePhotoSearchException>().having(
          (e) => e.failure,
          'failure',
          failure,
        ),
      );

      await expectLater(
        search.search('error'),
        fails(RecipePhotoSearchFailure.network),
      );
      await expectLater(
        search.search('busy'),
        fails(RecipePhotoSearchFailure.busy),
      );
      await expectLater(
        search.search('html'),
        fails(RecipePhotoSearchFailure.invalidResponse),
      );
      await expectLater(
        search.search('broken'),
        fails(RecipePhotoSearchFailure.invalidResponse),
      );
      await expectLater(
        search.search('silent'),
        fails(RecipePhotoSearchFailure.timeout),
      );
    });
  });

  group('photo credit', () {
    test('bounds text and requires a license and an HTTPS source', () {
      final long = RecipeImageCredit.tryCreate(
        title: 'x' * 1000,
        author: '  ',
        license: 'CC0',
        provider: recipePhotoProvider,
        sourceUrl: 'https://commons.wikimedia.org/wiki/File:X.jpg',
      )!;
      expect(long.title.length, maxRecipeImageCreditLength);
      expect(long.title, endsWith('…'));
      expect(long.author, isNull);

      final emoji = RecipeImageCredit.tryCreate(
        title: '${'x' * 298}🍜🍜',
        license: 'CC0',
        provider: recipePhotoProvider,
        sourceUrl: 'https://commons.wikimedia.org/wiki/File:X.jpg',
      )!;
      expect(emoji.title, '${'x' * 298}…');
      expect(
        RecipeImageCredit.tryFromJson(emoji.toJson()),
        emoji,
        reason: 'stored credits stay stable after a reload',
      );

      for (final source in [
        'http://commons.wikimedia.org/wiki/File:X.jpg',
        'javascript:alert(1)',
        'https://user:pw@commons.wikimedia.org/',
        'https://${'a' * 3000}.org/',
      ]) {
        expect(
          RecipeImageCredit.tryCreate(
            title: 'X',
            license: 'CC0',
            provider: recipePhotoProvider,
            sourceUrl: source,
          ),
          isNull,
          reason: source,
        );
      }
      expect(
        RecipeImageCredit.tryCreate(
          title: 'X',
          license: ' ',
          provider: recipePhotoProvider,
          sourceUrl: 'https://commons.wikimedia.org/',
        ),
        isNull,
      );
    });

    test('backup JSON keeps the credit; damaged credits keep the photo', () {
      final image = RecipeImage(
        recipeId: 'doener-vegan',
        bytes: testPngBytes(),
        updatedAt: DateTime.utc(2026, 10, 8),
        credit: _credit(),
      );
      final restored = RecipeImage.fromBackupJson(image.toBackupJson());
      expect(restored.credit, _credit());
      expect(restored.bytes, orderedEquals(testPngBytes()));

      final damaged = image.toBackupJson()
        ..['credit'] = {'title': 4, 'license': 'CC0'};
      final kept = RecipeImage.fromBackupJson(damaged);
      expect(kept.credit, isNull);
      expect(kept.bytes, orderedEquals(testPngBytes()));

      final device = RecipeImage(
        recipeId: 'doener-vegan',
        bytes: testPngBytes(),
        updatedAt: DateTime.utc(2026),
      );
      expect(device.toBackupJson().containsKey('credit'), isFalse);
    });
  });

  group('profile setting', () {
    test('is off by default, also for profiles saved before it existed', () {
      expect(const Profile().imageSearchEnabled, isFalse);
      final old = const Profile().toJson()..remove('image_search_enabled');
      expect(Profile.fromJson(old).imageSearchEnabled, isFalse);
      final enabled = const Profile().copyWith(imageSearchEnabled: true);
      expect(Profile.fromJson(enabled.toJson()).imageSearchEnabled, isTrue);
      expect(
        enabled.copyWith(name: 'x').imageSearchEnabled,
        isTrue,
        reason: 'unrelated edits keep the choice',
      );
    });
  });

  group('stored found photos', () {
    test('credit survives restart, backup restore and replacement', () async {
      final store = MemoryStore();
      final state = await _state(store);
      await state.setRecipeImage(
        'doener-vegan',
        testPngBytes(),
        credit: _credit(),
      );

      final reloaded = await _state(store);
      expect(reloaded.recipeImageFor('doener-vegan')?.credit, _credit());

      final backup = BackupService.import(
        BackupService.export(reloaded.buildBackup()).jsonFile,
      );
      expect(backup.recipeImages.single.credit, _credit());
      final restored = await _state(MemoryStore());
      await restored.applyBackup(backup, merge: false);
      expect(restored.recipeImageFor('doener-vegan')?.credit, _credit());

      // A device photo replaces the found one, and with it the credit.
      await reloaded.setRecipeImage('doener-vegan', testPngBytes());
      expect(reloaded.recipeImageFor('doener-vegan')?.credit, isNull);
      expect(
        (await _state(store)).recipeImageFor('doener-vegan')?.credit,
        isNull,
      );
    });

    test('recipe shares carry the credit to the recipient', () async {
      final sender = await _state(MemoryStore());
      await sender.toggleSaved('doener-vegan');
      await sender.setRecipeImage(
        'doener-vegan',
        testPngBytes(),
        credit: _credit(),
      );
      final data = await collectRecipeShare(
        sender,
        recipeId: 'doener-vegan',
        includeImages: true,
      );
      expect(data.images.single.credit, _credit());
      final text = recipeShareText(data, lang: 'en');
      expect(
        text,
        contains(
          'Photo: Pad thai mound · Ann · CC BY-SA 2.0 · Wikimedia Commons · '
          'https://commons.wikimedia.org/wiki/File:Pad_thai_mound.jpg',
        ),
      );

      final received = decodeRecipeShare(encodeRecipeShare(data));
      final recipient = await _state(MemoryStore());
      await recipient.importSharedRecipes(received);
      expect(recipient.recipeImages.single.credit, _credit());
    });
  });
}
