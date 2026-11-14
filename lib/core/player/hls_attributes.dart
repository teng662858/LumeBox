/// Keep quoting intact so a locally rewritten tag preserves its attribute types.
Map<String, String> hlsRawAttributes(String tag) => {
  for (final match in _attribute.allMatches(
    tag.substring(tag.indexOf(':') + 1),
  ))
    match[1]!: match[2]!,
};

final _attribute = RegExp(r'(?:^|,)([A-Z0-9-]+)=("[^"]*"|[^,]*)');

/// Offsets cover just the URL so the rest of the original tag is preserved.
Iterable<({int start, int end, String value})> hlsUriAttributes(String line) sync* {
  if (!line.startsWith('#EXT-X-')) return;
  final colon = line.indexOf(':');
  if (colon < 0) return;
  for (final match in _attribute.allMatches(line.substring(colon + 1))) {
    final name = match[1]!;
    final raw = match[2]!;
    if ((name == 'URI' || name.endsWith('-URI')) &&
        raw.length > 2 && raw.startsWith('"') && raw.endsWith('"')) {
      final end = colon + match.end;
      final value = hlsAttributeValue(raw);
      yield (start: end - value.length, end: end, value: value);
    }
  }
}

String hlsAttributeValue(String raw) =>
    raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')
    ? raw.substring(1, raw.length - 1)
    : raw;

String hlsTag(String name, Map<String, String> attributes) =>
    '$name:${attributes.entries.map((entry) => '${entry.key}=${entry.value}').join(',')}';
