// The readers under the doctor: the old-style property lists of project.pbxproj, .xcconfig includes, XML property
// lists and manifests, dotted versions, llamadart's runtime selection, hook targets and the native manifest (the
// embedded copy equals tool/native/llamadart-native-v0.4.0.sha256).
import 'dart:io';

import 'package:local_inference/src/doctor/checks_pub.dart';
import 'package:local_inference/src/doctor/context.dart';
import 'package:local_inference/src/doctor/native_manifest.g.dart';
import 'package:local_inference/src/doctor/natives.dart';
import 'package:local_inference/src/doctor/xcode.dart';
import 'package:local_inference/src/doctor/xml.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('old-style property lists (project.pbxproj)', () {
    test('dictionaries, arrays, quoted and bare strings, comments', () {
      final value = parseOpenStepPlist(r'''
// !$*UTF8*$!
{
  /* a comment */ key = value; // to the end of the line
  "quoted key" = "a \"quoted\" \\ value\nwith a new line";
  list = (a, "b c", 16.4, );
  empty = ( );
  nested = { isa = PBXGroup; path = Flutter/Debug.xcconfig; sourceTree = "<group>"; };
  data = <0fbd 7777>;
  unicode = "\U00e8";
}
''');
      expect(value, {
        'key': 'value',
        'quoted key': 'a "quoted" \\ value\nwith a new line',
        'list': ['a', 'b c', '16.4'],
        'empty': <Object?>[],
        'nested': {'isa': 'PBXGroup', 'path': 'Flutter/Debug.xcconfig', 'sourceTree': '<group>'},
        'data': '<0fbd 7777>',
        'unicode': 'è',
      });
    });

    test('malformed text throws FormatException', () {
      for (final text in ['{ a = b }', '{ a b; }', '( a b )', '{ a = "b; }', '/* open', '{ a = b; } c']) {
        expect(() => parseOpenStepPlist(text), throwsFormatException, reason: text);
      }
    });

    test('a build setting resolves from the target, its xcconfig, then the project; groups give file paths', () {
      final dir = Directory.systemTemp.createTempSync('xcode_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(
        p.join('test', 'fixtures', 'doctor', 'flutter_host', 'ios', 'Runner.xcodeproj', 'project.pbxproj'),
      ).copySync(p.join((Directory(p.join(dir.path, 'Runner.xcodeproj'))..createSync()).path, 'project.pbxproj'));
      File(p.join(dir.path, 'Flutter', 'Debug.xcconfig'))
        ..createSync(recursive: true)
        ..writeAsStringSync('#include? "missing.xcconfig"\n#include "Base.xcconfig"\nSWIFT_VERSION = 6.0\n');
      File(p.join(dir.path, 'Flutter', 'Base.xcconfig')).writeAsStringSync(
        'SWIFT_VERSION = 5.0 // overridden below the include\nENABLE_BITCODE = NO;\nOTHER[sdk=iphoneos*] = x\n',
      );
      final project = XcodeProject.read(XcodeProject.find(dir.path)!);
      final debug = project.appTarget!.configs.first;
      expect((debug.name, project.appTarget!.name), ('Debug', 'Runner'));
      expect(debug.setting('CODE_SIGN_ENTITLEMENTS'), 'Runner/Runner.entitlements');
      expect(debug.settingSource('CODE_SIGN_ENTITLEMENTS'), 'target');
      expect((debug.setting('SWIFT_VERSION'), debug.settingSource('SWIFT_VERSION')), ('6.0', 'target xcconfig'));
      expect(debug.setting('ENABLE_BITCODE'), 'NO');
      expect(debug.setting('OTHER'), isNull, reason: 'conditional settings are not read');
      expect(
        (debug.setting('IPHONEOS_DEPLOYMENT_TARGET'), debug.settingSource('IPHONEOS_DEPLOYMENT_TARGET')),
        ('16.4', 'project'),
      );
      expect(debug.setting('NOT_SET'), isNull);
      final resources = project.appTarget!.phases.singleWhere((ph) => ph.isa == 'PBXResourcesBuildPhase');
      expect(resources.filePaths, [
        p.join(dir.path, 'Runner', 'Assets.xcassets'),
        p.join(dir.path, 'Runner', 'PrivacyInfo.xcprivacy'),
      ]);
      expect(project.appTarget!.phases.map((ph) => ph.name), [
        'Run Script',
        'PBXSourcesBuildPhase',
        'PBXFrameworksBuildPhase',
        'PBXResourcesBuildPhase',
        'Embed Frameworks',
        'Thin Binary',
        'Native Assets Minimum iOS',
      ]);
    });

    test('dotted versions', () {
      expect(compareDottedVersions('16.4', '16.4'), 0);
      expect(compareDottedVersions('16.4.1', '16.4'), greaterThan(0));
      expect(compareDottedVersions('17', '16.4'), greaterThan(0));
      expect(compareDottedVersions('13.0', '16.4'), lessThan(0));
      expect(compareDottedVersions('10.15', '14.0'), lessThan(0));
      expect(compareDottedVersions('9.0', '16.4'), lessThan(0), reason: 'numbers, not text');
      expect(compareDottedVersions('16.10', '16.4'), greaterThan(0), reason: 'numbers, not text');
      expect(compareDottedVersions(r'$(RECOMMENDED)', '16.4'), isNull);
    });
  });

  group('source text', () {
    test('comments go; strings (an escaped quote does not end one), line numbers and a // in a string stay', () {
      expect(
        stripComments('a // one\nb /* two\nlines */ c\n"d // e" \'f /* g */\' "h\\"// i"\nj'),
        'a \nb \n c\n"d // e" \'f /* g */\' "h\\"// i"\nj',
      );
      expect(stripComments('x = "https://example.com/a" // why\n'), 'x = "https://example.com/a" \n');
      expect(stripComments('open /* never closed\nstill'), 'open \n');
    });

    test('a statement runs to the end of its line, across open brackets and trailing commas or operators', () {
      String first(String text) => statementAt(text, text.indexOf('abiFilters'));
      expect(first('abiFilters += listOf("a")\nnext()'), 'abiFilters += listOf("a")');
      expect(first('abiFilters += listOf(\n  "a",\n  "b",\n)\nnext()'), 'abiFilters += listOf(\n  "a",\n  "b",\n)');
      expect(first("abiFilters 'a',\n  'b'\nnext"), "abiFilters 'a',\n  'b'");
      expect(first('abiFilters +=\n  setOf("a")\n'), 'abiFilters +=\n  setOf("a")');
      expect(first('ndk { abiFilters.add("a") }'), 'abiFilters.add("a")');
      expect(first('abiFilters.add("a"); abiFilters.add("b")'), 'abiFilters.add("a")');
      expect(first('abiFilters.add(")")\n'), 'abiFilters.add(")")', reason: 'a bracket in a string');
    });
  });

  group('XML', () {
    test('a property list: dict, array, booleans, numbers, entities, comments, CDATA', () {
      expect(
        parsePlist('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- a comment -->
  <key>text</key><string>a &lt;b&gt; &amp; &#233;&#x20AC;</string>
  <key>cdata</key><string><![CDATA[<raw>]]></string>
  <key>list</key><array><true/><false/><integer>42</integer><real>1.5</real><array/></array>
  <key>empty</key><dict/>
</dict>
</plist>'''),
        {
          'text': 'a <b> & é€',
          'cdata': '<raw>',
          'list': [true, false, 42, 1.5, <Object?>[]],
          'empty': <String, Object?>{},
        },
      );
    });

    test('attributes keep their prefix; bad XML and other formats throw', () {
      final manifest = parseXml(
        '<manifest xmlns:android="x"><application android:label=\'A &amp; B\'><service android:name="S"/>'
        '</application></manifest>',
      );
      final service = manifest.descendants.singleWhere((e) => e.name == 'service');
      expect(service.attributes, {'android:name': 'S'});
      expect(manifest.children.single.attributes['android:label'], 'A & B');
      for (final text in ['<a><b></a>', '<a>', '<a/><b/>', 'text', '<a x=1/>']) {
        expect(() => parseXml(text), throwsFormatException, reason: text);
      }
      expect(() => parsePlist('bplist00...'), throwsFormatException);
      expect(() => parsePlist('<dict/>'), throwsFormatException);
      expect(() => parsePlist('<plist><dict><key>a</key></dict></plist>'), throwsFormatException);
    });
  });

  test('the runtime selection follows llamadart 0.8.23: aliases, all, none, unknown tokens, maps', () {
    ({Set<String> runtimes, List<String> unknown})? s(Object? value) => selectedRuntimes(value);
    expect(s(['llama_cpp'])!.runtimes, {'llama_cpp'});
    expect(s('llama.cpp')!.runtimes, {'llama_cpp'});
    expect(s(['GGUF', 'llamacpp'])!.runtimes, {'llama_cpp'});
    expect(s('llama_cpp, litert')!.runtimes, {'llama_cpp', 'litert_lm'});
    expect(s(['all'])!.runtimes, {'llama_cpp', 'litert_lm'});
    expect(s(null)!.runtimes, {'llama_cpp', 'litert_lm'}, reason: 'unset: every runtime');
    expect(s(<Object?>[])!.runtimes, {'llama_cpp', 'litert_lm'}, reason: 'nothing recognised: every runtime');
    expect(s(['none', 'llama_cpp'])!.runtimes, {'llama_cpp'});
    expect(s(['llama_cpp', 'none'])!.runtimes, isEmpty);
    expect(s(false)!.runtimes, isEmpty);
    final withUnknown = s(['llama_cpp', 'tflite'])!;
    expect((withUnknown.runtimes.join(), withUnknown.unknown.join()), ('llama_cpp', 'tflite'));
    expect(s({'platforms': <String, Object?>{}}), isNull);
  });

  test('hook targets and ABIs map to llama.cpp bundles', () {
    expect(bundleForTarget(os: 'ios', architecture: 'arm64', iosSdk: 'iphoneos'), 'ios-arm64');
    expect(bundleForTarget(os: 'ios', architecture: 'arm64', iosSdk: 'iphonesimulator'), 'ios-arm64-sim');
    expect(bundleForTarget(os: 'macos', architecture: 'x64'), 'macos-x86_64');
    expect(bundleForTarget(os: 'android', architecture: 'arm64'), 'android-arm64');
    expect(bundleForTarget(os: 'android', architecture: 'arm'), isNull);
    expect(
      [androidBundleForAbi('arm64-v8a'), androidBundleForAbi('x86_64'), androidBundleForAbi('armeabi-v7a')],
      ['android-arm64', 'android-x64', null],
    );
  });

  group('the native manifest', () {
    test('the embedded copy is tool/native/llamadart-native-v0.4.0.sha256, byte for byte', () {
      final file = File(p.join('tool', 'native', 'llamadart-native-$nativeManifestTag.sha256')).readAsStringSync();
      expect(
        nativeManifestText,
        file,
        reason: 'run dart run tool/embed_native_manifest.dart in packages/local_inference',
      );
    });

    test('its bundles, archives and files', () {
      final manifest = NativeManifest.embedded;
      expect(manifest.tag, 'v0.4.0');
      expect(manifest.bundles, [
        'android-arm64',
        'android-x64',
        'ios-arm64',
        'ios-arm64-sim',
        'linux-x64',
        'macos-arm64',
        'macos-x86_64',
      ]);
      expect(
        manifest.sha256ByPath['macos-arm64/${manifest.archiveName('macos-arm64')}'],
        '95e76865fb444f3187da47398cfab03a0af3ad46da6a9026e1d490401401355a',
      );
      expect(manifest.extractedSha256('ios-arm64', 'libllamadart.dylib'), startsWith('53ecab5b'));
      expect(manifest.filesOf('android-arm64'), hasLength(16));
      expect(manifest.sha256ByPath[NativeManifest.guardPath], startsWith('e3b0c442'), reason: 'the empty file');
      expect(() => NativeManifest.parse('not a line', tag: 'v0'), throwsFormatException);
    });

    test('a symlink in a bundle folder is a problem, since the hook copies what it finds', () {
      final dir = Directory.systemTemp.createTempSync('natives_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bundle = Directory(p.join(dir.path, 'b', 'extracted'))..createSync(recursive: true);
      final library = File(p.join(bundle.path, 'lib.so'))..writeAsStringSync('a library');
      final manifest = NativeManifest.parse('${sha256OfFile(library.path)}  b/extracted/lib.so\n', tag: 'v1');
      expect(sha256OfFile(library.path), '31f109ab38348582abdc9e1c9942f74505c719e98c6d0ab6fbcfdccfd8c9935b');
      Link(p.join(bundle.path, 'lib.so.1')).createSync('lib.so');
      final check = verifyBundleFolder(manifest, 'b', p.join(dir.path, 'b'), archiveOptional: true);
      expect(check.matched, 1);
      expect(check.problems, ['b/extracted/lib.so.1 is a symlink']);
    });
  });
}
