import Foundation

func checkNativeMPVState() {
  var state = NativeVideoState()
  // NSDictionary callbacks import as AnyHashable keys, not String keys.
  var snapshot: [AnyHashable: Any] = ["position": 47.0, "duration": 120.0, "buffered": 8.0,
    "ready": true, "playing": true, "buffering": false, "ended": false,
    "width": 1920, "height": 1080, "tracks": [["type": "audio", "id": 1]], 1: "ignored"]
  state.updateFromMPV(snapshot)
  state.firstFrame = true
  precondition(state.position == 47 && state.playing && state.ready)

  state.updateFromMPV(["error": "network failure", "buffering": false])
  precondition(state.position == 47 && state.duration == 120 && state.firstFrame)
  precondition(state.width == 1920 && state.tracks.count == 1)
  precondition(!state.playing && !state.buffering && !state.ready && state.error != nil)
  state.updateFromMPV(["error": "network failure", "position": 0.0, "duration": 0.0,
    "playing": true, "buffering": true, "ready": true])
  precondition(state.position == 47 && state.duration == 120 && !state.playing && !state.buffering)

  snapshot["buffering"] = true
  state.updateFromMPV(snapshot)
  precondition(state.error == nil && state.buffering && !state.playing)
  snapshot["buffering"] = false
  state.updateFromMPV(snapshot)
  precondition(state.playing && !state.buffering)

  snapshot["position"] = 0.0
  state.updateFromMPV(snapshot)
  precondition(state.position == 0, "A real seek to zero must replace the previous position")
  snapshot["ended"] = true
  state.updateFromMPV(snapshot)
  precondition(state.ended && !state.playing)
  snapshot["ended"] = false; snapshot["ready"] = false
  state.updateFromMPV(snapshot)
  precondition(!state.playing)

  state = NativeVideoState()
  state.updateFromMPV(["error": "cannot open media"])
  precondition(state.position == 0 && state.duration == 0 && !state.firstFrame)
  print("NATIVE_MPV_STATE_OK")
}
