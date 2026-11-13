/// Keep quoting intact so a locally rewritten tag preserves its attribute types.
Map<String, String> hlsRawAttributes(String tag) => {
  for (final match in _attribute.allMatches(
    tag.substring(tag.indexOf(':') + 1),
  ))
    match[1]!: match[2]!,
};

final _attribute = RegExp(r'(?:^|,)([A-Z0-9-]+)=("[^"]*"|[^,]*)');

String hlsAttributeValue(String raw) =>
    raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')
    ? raw.substring(1, raw.length - 1)
    : raw;

String hlsTag(String name, Map<String, String> attributes) =>
    '$name:${attributes.entries.map((entry) => '${entry.key}=${entry.value}').join(',')}';
