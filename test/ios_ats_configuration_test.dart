import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test('plain HTTP source exception is limited to its exact IP address', () {
    final document = XmlDocument.parse(
      File('ios/Runner/Info.plist').readAsStringSync(),
    );
    final root = document.rootElement.getElement('dict')!;
    final appTransportSecurity = _valueFor(root, 'NSAppTransportSecurity');
    final domains = _valueFor(appTransportSecurity, 'NSExceptionDomains');
    final sourceHost = _valueFor(domains, '103.45.132.22');

    expect(
      _valueFor(sourceHost, 'NSExceptionAllowsInsecureHTTPLoads').name.local,
      'true',
    );
    expect(_valueFor(sourceHost, 'NSIncludesSubdomains').name.local, 'false');
    expect(
      root.descendantElements
          .where((element) => element.name.local == 'key')
          .map((element) => element.innerText.trim()),
      isNot(contains('NSAllowsArbitraryLoads')),
    );
  });
}

XmlElement _valueFor(XmlElement dictionary, String name) {
  final children = dictionary.children.whereType<XmlElement>().toList();
  for (var index = 0; index + 1 < children.length; index += 2) {
    if (children[index].name.local == 'key' &&
        children[index].innerText.trim() == name) {
      return children[index + 1];
    }
  }
  throw StateError('Missing plist key: $name');
}
