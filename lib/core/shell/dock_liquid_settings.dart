import 'package:flutter/foundation.dart';

enum DockLiquidEffect {
  lift('水滴鼓起', '按住时水滴浮出长胶囊边缘'),
  drag('拖动拉伸', '跟随拖动速度、方向和离落点距离改变形状'),
  capsule('胶囊联动', '下方长胶囊随触摸轻微伸缩'),
  clarity('按压变清透', '按住时减弱磨砂与白色遮盖，松手恢复'),
  optics('透镜折射', '让图标、文字和背景一起参与折射'),
  lighting('高光与阴影联动', '水滴鼓起时加强边缘反光和投影');

  const DockLiquidEffect(this.label, this.description);
  final String label, description;
}

enum DockLiquidParameter {
  pressMs('按压响应时间', '数值越小，按下后鼓起越快。', 100, 50, 400),
  damping('回弹阻尼', '越低越有弹性，越高越平稳；动效时长仍控制回弹速度。', .58, .3, 1),
  lift('水滴鼓起高度', '相对静止水滴高度增加的比例。', .48, 0, 1, DockLiquidEffect.lift),
  spread('按压横向膨胀', '按住时向两侧扩展的幅度。', .22, 0, .8, DockLiquidEffect.lift),
  vertical(
    '上下跟手幅度',
    '手指靠近上沿或下沿时，水滴跟着轻微偏移。',
    .09,
    0,
    .25,
    DockLiquidEffect.lift,
  ),
  stretch('拖动拉伸幅度', '拖得越快、离落点越远，水滴拉得越长。', .65, 0, 1.2, DockLiquidEffect.drag),
  tail('拖尾收窄程度', '水滴后端收窄，转向时拖尾也会换方向。', .55, 0, .9, DockLiquidEffect.drag),
  capsuleX('胶囊横向伸缩', '下方长胶囊左右伸缩的幅度。', .014, 0, .06, DockLiquidEffect.capsule),
  capsuleY('胶囊纵向伸缩', '下方长胶囊上下伸缩的幅度。', .065, 0, .18, DockLiquidEffect.capsule),
  blurReduction(
    '按压磨砂减弱',
    '0% 保持原磨砂，100% 按到底时去掉磨砂。',
    .62,
    0,
    1,
    DockLiquidEffect.clarity,
  ),
  opacityReduction(
    '按压白度减弱',
    '按住时减少白色遮盖；全透和全白端点保持原设置。',
    .24,
    0,
    1,
    DockLiquidEffect.clarity,
  ),
  refraction(
    '折射放大强度',
    '调整图标、文字和背景被透镜放大、拉弯的程度。',
    1,
    0,
    2.5,
    DockLiquidEffect.optics,
  ),
  dispersion(
    '边缘彩色折光',
    '水滴边缘红蓝分色的强度；0% 无彩色折光。',
    1,
    0,
    2.5,
    DockLiquidEffect.optics,
  ),
  highlight(
    '按压高光增强',
    '在现有边缘高光设置上增加反光，原高光为零时不额外开启。',
    .6,
    0,
    1.5,
    DockLiquidEffect.lighting,
  ),
  shadow(
    '按压阴影增强',
    '相对现有阴影浓度增强，原阴影为零时仍然无阴影。',
    2.2,
    0,
    4,
    DockLiquidEffect.lighting,
  );

  const DockLiquidParameter(
    this.label,
    this.description,
    this.initial,
    this.min,
    this.max, [
    this.effect,
  ]);
  final String label, description;
  final double initial, min, max;
  final DockLiquidEffect? effect;
  bool get milliseconds => this == pressMs;
  String display(double value) => milliseconds
      ? '${value.round()} ms'
      : '${(value * 100).toStringAsFixed(this == capsuleX || this == capsuleY ? 1 : 0)}%';
}

/// Stored inside the existing dock appearance; missing fields use safe defaults.
@immutable
class DockLiquidSettings {
  const DockLiquidSettings({this.values = const {}, this.disabled = const {}});
  final Map<String, double> values;
  final Set<String> disabled;

  double value(DockLiquidParameter parameter) =>
      values[parameter.name] ?? parameter.initial;
  bool enabled(DockLiquidEffect effect) => !disabled.contains(effect.name);

  DockLiquidSettings withValue(DockLiquidParameter parameter, double amount) =>
      DockLiquidSettings(
        values: Map.unmodifiable({
          ...values,
          parameter.name: amount.isFinite
              ? amount.clamp(parameter.min, parameter.max)
              : parameter.initial,
        }),
        disabled: disabled,
      );

  DockLiquidSettings withEnabled(DockLiquidEffect effect, bool enable) {
    final next = Set<String>.of(disabled);
    if (enable) {
      next.remove(effect.name);
    } else {
      next.add(effect.name);
    }
    return DockLiquidSettings(values: values, disabled: Set.unmodifiable(next));
  }

  Map<String, Object?> toJson() => {
    'values': values,
    'disabled': disabled.toList(),
  };
  static DockLiquidSettings fromJson(Object? data) {
    if (data is! Map) return const DockLiquidSettings();
    var result = const DockLiquidSettings();
    final rawValues = data['values'];
    if (rawValues is Map) {
      for (final parameter in DockLiquidParameter.values) {
        final raw = rawValues[parameter.name];
        if (raw is num) result = result.withValue(parameter, raw.toDouble());
      }
    }
    final rawDisabled = data['disabled'];
    if (rawDisabled is List) {
      for (final effect in DockLiquidEffect.values) {
        if (rawDisabled.contains(effect.name)) {
          result = result.withEnabled(effect, false);
        }
      }
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is DockLiquidSettings &&
      DockLiquidParameter.values.every((p) => value(p) == other.value(p)) &&
      DockLiquidEffect.values.every((e) => enabled(e) == other.enabled(e));
  @override
  int get hashCode => Object.hash(
    Object.hashAll(DockLiquidParameter.values.map(value)),
    Object.hashAll(DockLiquidEffect.values.map(enabled)),
  );
}
