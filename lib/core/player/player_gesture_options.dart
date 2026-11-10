class PlayerGestureOptions {
  const PlayerGestureOptions({
    this.enabled = true,
    this.brightness = true,
    this.volume = true,
    this.seek = true,
    this.boost = true,
    this.seekSeconds = 90,
    this.forwardSeconds = 10,
    this.backwardSeconds = 10,
    this.boostMultiplier = 2,
  });
  final bool enabled, brightness, volume, seek, boost;
  final int seekSeconds, forwardSeconds, backwardSeconds;
  final double boostMultiplier;
  PlayerGestureOptions copyWith({
    bool? enabled,
    bool? brightness,
    bool? volume,
    bool? seek,
    bool? boost,
    int? seekSeconds,
    int? forwardSeconds,
    int? backwardSeconds,
    double? boostMultiplier,
  }) => PlayerGestureOptions(
    enabled: enabled ?? this.enabled,
    brightness: brightness ?? this.brightness,
    volume: volume ?? this.volume,
    seek: seek ?? this.seek,
    boost: boost ?? this.boost,
    seekSeconds: (seekSeconds ?? this.seekSeconds).clamp(30, 180),
    forwardSeconds: (forwardSeconds ?? this.forwardSeconds).clamp(1, 300),
    backwardSeconds: (backwardSeconds ?? this.backwardSeconds).clamp(1, 300),
    boostMultiplier: (boostMultiplier ?? this.boostMultiplier).clamp(1.5, 4),
  );
  Map<String, Object> toJson() => {
    'enabled': enabled,
    'brightness': brightness,
    'volume': volume,
    'seek': seek,
    'boost': boost,
    'seekSeconds': seekSeconds,
    'forwardSeconds': forwardSeconds,
    'backwardSeconds': backwardSeconds,
    'boostMultiplier': boostMultiplier,
  };
  factory PlayerGestureOptions.fromJson(Object? raw) {
    final m = raw is Map ? raw : const {};
    final seconds = m['seekSeconds'];
    final multiplier = m['boostMultiplier'];
    return PlayerGestureOptions(
      enabled: m['enabled'] != false,
      brightness: m['brightness'] != false,
      volume: m['volume'] != false,
      seek: m['seek'] != false,
      boost: m['boost'] != false,
      seekSeconds: seconds is num && seconds.isFinite
          ? seconds.toInt().clamp(30, 180)
          : 90,
      forwardSeconds: step(m['forwardSeconds']),
      backwardSeconds: step(m['backwardSeconds']),
      boostMultiplier: multiplier is num && multiplier.isFinite
          ? multiplier.toDouble().clamp(1.5, 4)
          : 2,
    );
  }
  static int step(Object? n) =>
      n is num && n.isFinite ? n.toInt().clamp(1, 300) : 10;
  @override
  bool operator ==(Object other) =>
      other is PlayerGestureOptions &&
      other.enabled == enabled &&
      other.brightness == brightness &&
      other.volume == volume &&
      other.seek == seek &&
      other.boost == boost &&
      other.seekSeconds == seekSeconds &&
      other.forwardSeconds == forwardSeconds &&
      other.backwardSeconds == backwardSeconds &&
      other.boostMultiplier == boostMultiplier;
  @override
  int get hashCode => Object.hash(
    enabled,
    brightness,
    volume,
    seek,
    boost,
    seekSeconds,
    forwardSeconds,
    backwardSeconds,
    boostMultiplier,
  );
}
