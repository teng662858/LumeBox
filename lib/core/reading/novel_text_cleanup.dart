/// Remove known source artifacts while keeping old reading checkpoints usable.
({String text, int offset}) cleanNovelText(String text, {int offset = 0}) {
  final originalOffset = offset.clamp(0, text.length);
  var mappedOffset = originalOffset;
  var cursor = 0;
  final result = StringBuffer();
  for (final match in _novelArtifacts.allMatches(text)) {
    result.write(text.substring(cursor, match.start));
    mappedOffset -= (originalOffset - match.start).clamp(
      0,
      match.end - match.start,
    );
    cursor = match.end;
  }
  if (cursor == 0) return (text: text, offset: originalOffset);
  result.write(text.substring(cursor));
  return (text: result.toString(), offset: mappedOffset);
}

final _novelArtifacts = RegExp(
  // The marker and known domain are required together. Leave ordinary links,
  // braces, and backslashes alone. The obfuscated suffix stops at prose.
  r'发[布佈][\\/ \t]*[页頁][\\/ \t]*地址[ \t\r\n{｛【\[]{0,16}(?:https?://)?(?:www[.．])?ltxsfb[.．]com'
  r'(?:[l|｜]?[ \t]*[tᴛ][ \t]*x[ \t]*s[ \t]*b[ \t]*a[.．][cＣｃ][oＯｏ〇][mＭｍ])?'
  r'(?:[.．…°·]+[cＣｃ][oＯｏ〇][mＭｍ])?[}｝】\]]?'
  r'|\\+(?=["“”])',
  caseSensitive: false,
);
