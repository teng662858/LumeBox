enum SpeechMode {
  system('系统朗读'),
  local('sherpa-onnx离线朗读'),
  kokoro('Kokoro 离线朗读'),
  cloud('在线朗读 · 标准'),
  cloudAi('在线朗读 · 智能');

  const SpeechMode(this.label);
  final String label;
  static SpeechMode parse(Object? name) =>
      values.where((m) => m.name == name).firstOrNull ?? system;
}
