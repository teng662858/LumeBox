import Foundation

func checkNativeSubtitles() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  let vtt = [
    "WEBVTT", "", "00:02.000 --> 00:04.000", "World", "",
    "00:01.000 --> 00:03.000 align:start", "<b>你好</b> &amp; &lt;角色&gt; &amp;lt;", "",
    "NOTE ignored", "00:01.000 --> 00:05.000", "comment", "",
  ].joined(separator: "\r")
  for encoding in [String.Encoding.utf8, .utf16] {
    try vtt.write(to: url, atomically: true, encoding: encoding)
    let timeline = NativeVideoSubtitles.read(url)
    precondition(timeline?.caption(at: 2) == "你好 & <角色> &lt;\nWorld")
    precondition(timeline?.caption(at: 3) == "World")
    precondition(timeline?.caption(at: 4) == nil)
    precondition(timeline?.caption(at: 1) == "你好 & <角色> &lt;")
  }
  let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nfirst\r\nsecond"
  try srt.write(to: url, atomically: true, encoding: .utf8)
  precondition(NativeVideoSubtitles.read(url)?.caption(at: 1.5) == "first\nsecond")
  try "unreadable caption".write(to: url, atomically: true, encoding: .utf8)
  precondition(NativeVideoSubtitles.read(url) == nil)
}
