import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../core/shell/shell_settings.dart';
import '../../core/theme/floating_modules.dart';
import '../../core/theme/lume_theme.dart';
import 'dock_liquid_lens.dart';
import '../../core/theme/icon_customization.dart';

/// 底部 Dock 里的一条页签（只有展示数据，不含页面构造）。
///
/// 壳层与设置页的真实预览共用这一份数据形状：设置页里看到的就是壳层里跑的
/// 同一个 [ShellDockBar]，不存在「预览一套、线上另一套」。
class ShellDockEntry {
  const ShellDockEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  /// 稳定标识（与 [ShellTab.id] 同源）。
  final String id;

  final String label;

  /// 未选中 / 选中图标。
  final IconData icon;
  final IconData selectedIcon;
}

/// 底部悬浮 Dock：真实毛玻璃胶囊 + 可拖拽、会拉伸、松手弹簧吸附的水滴。
///
/// 结构分四层，基础胶囊与水滴各自裁剪，按压水滴可越过胶囊边缘：
/// 1. [ClipRRect] + [BackdropFilter]：把**背后的页面内容**真正模糊掉，
///    白度（[FloatingStyle.opacity]）与磨砂强度（[FloatingStyle.blur]）都来自
///    「设置 → 底部导航栏管理」，滑块拖动时立刻重绘；
/// 2. 水滴层：单独一颗 [Positioned] 的水滴，位置、宽度与形状由
///    [AnimationController] 驱动。拖动时直接写值跟手，宽度同时由**速度**和
///    **离最近页签的距离**决定；路径在静止胶囊与「尾部收窄、轻微压扁」的
///    液态水滴之间插值。松手后分别用 [SpringSimulation] 把「中心所在页签」
///    和「宽度 / 形状」弹回目标；
/// 3. 页签内容层：图标 + 文案，颜色随选中态过渡；
/// 4. 透镜层：在图标之后折射已经绘制的图标、文字与背景，不重复构建页签。
///
/// 手势全部落在包裹内容的 [GestureDetector] 上：水平拖动由它赢过页签的
/// [InkWell] 点击；点击则走 [InkWell] 与 [GestureDetector.onTapUp] 两条路，
/// 都汇到同一个 [_selectIndex]，不会出现「拖一套、点另一套」。
///
/// **设置绑定**：尺寸（高度 / 左右留白 / 离底，含负数压底）、玻璃白度、
/// 磨砂强度、边缘高光、阴影、点击弹跳开关与动效时长全部沿用原有字段，
/// 新增液态参数来自 [DockAppearance.liquid]，设置页与实际底栏实时共用。
class ShellDockBar extends StatefulWidget {
  const ShellDockBar({
    super.key,
    required this.entries,
    required this.activeId,
    required this.onSelect,
    required this.appearance,
    this.contentInset = 0,
    this.bottomMargin = 0,
    this.visible = true,
    this.applyViewPadding = true,
  });

  /// 水滴（选中底座）的定位键（测试与截图预览按它量位置 / 宽度）。
  static const Key selectionPillKey = Key('shell.dock.selectionPill');
  static const Key capsuleSurfaceKey = Key('shell.dock.capsuleSurface');
  static const Key capsuleFilterKey = Key('shell.dock.capsuleFilter');

  /// 胶囊内左右留白：首尾页签离圆角留一档，五项之间的净间距也跟着收紧。
  static const double innerPadding = 6;

  /// 水滴的最大宽度：页签很少时（用户隐藏到只剩 1–2 个）不会摊成一整条。
  static const double maxPillWidth = 104;

  /// 水滴在内容区上下各留的距离。
  static const double _dropInset = 4;

  final List<ShellDockEntry> entries;
  final String activeId;
  final ValueChanged<String> onSelect;

  /// 尺寸 / 玻璃边缘 / 投影 / 动效（设置页实时改）。
  final DockAppearance appearance;

  /// 胶囊**内部**给系统手势条让出的高度：外框照样画到底，只是里面的
  /// 图标与文字往上缩这一段。
  final double contentInset;

  /// 胶囊外框离屏幕底边的距离：0 = 外框直接画到屏幕底边。
  final double bottomMargin;

  /// 显隐：隐藏时整块（含内边距）平移到屏幕下沿之外，不占视觉、不响应点击。
  final bool visible;

  /// 是否叠加系统安全区左右留白。壳层里为 true；设置页里的内嵌预览为 false
  /// （否则横屏刘海会把预览条挤偏）。
  final bool applyViewPadding;

  /// 胶囊总高（外框）= 内容条 + 手势条避让。
  double get capsuleHeight => appearance.height + contentInset;

  @override
  State<ShellDockBar> createState() => _ShellDockBarState();
}

class _ShellDockBarState extends State<ShellDockBar>
    with TickerProviderStateMixin {
  /// 水滴中心所在的「连续页签坐标」：0 = 第一项中心，1 = 第二项中心……
  ///
  /// 用页签坐标而不是像素：横竖屏切换、隐藏页签、改左右留白时槽宽会变，
  /// 但「水滴在哪两个页签之间」不需要重算，重建时会自然落到新槽位。
  late final AnimationController _indexController;

  /// 水滴宽度相对基准宽度的倍率（拖动时 > 1，松手后弹簧回 1）。
  late final AnimationController _widthController;

  /// 拖动期间用来让速度自然衰减：手指停住时水滴不会一直保持被拉长的样子。
  late final Ticker _dragTicker;

  /// 按压进度：0 = 未按，1 = 按到底。松手用同一个弹簧回 0，产生水球回弹。
  late final AnimationController _pressController;

  // Vertical grip has its own short response and release spring. It is sampled
  // from touch position, not device pressure (normally constant on iPhones).
  DockLiquidSettings get _liquid => widget.appearance.liquid;
  double _amount(DockLiquidParameter p) => _liquid.value(p);
  double get _stretchFraction {
    final range = _amount(DockLiquidParameter.stretch);
    if (!_liquid.enabled(DockLiquidEffect.drag) || range <= 0) return 0;
    return ((_widthController.value - 1) / range).clamp(0.0, 1.0);
  }

  late final AnimationController _gripController;
  int? _pressedPointer;

  bool get _motionEnabled =>
      widget.appearance.animateSelection &&
      !IconCustomization.instance.editMode &&
      !MediaQuery.disableAnimationsOf(context);

  /// 手指在内容区的位置对「聚焦」的贡献（0 = 页签边缘，1 = 图标/文字中心）。
  ///
  /// 用 ValueNotifier 而不是 setState：指针移动只重建水滴这一层，
  /// 不把整个 Dock / 页面卷进 setState。
  late final ValueNotifier<double> _pointerFocus = ValueNotifier<double>(0);

  late final Listenable _dropAnimation;

  /// 当前「已经落定」的页签下标（页面实际停在哪一项）。
  int _resolvedIndex = 0;

  /// 最近一次吸附目标（弹簧完成时用来消掉亚像素残差）。
  int _targetIndex = 0;

  bool _dragging = false;

  /// 平滑后的水平速度（px/s），用于把水滴拉成橡皮筋。
  double _dragVelocity = 0;

  /// 当前拖动点离最近页签中心的「拉力」（0 = 正在页签中心，1 = 两页签正中间）。
  ///
  /// 只看速度的话，慢慢拖不会有形变，像一块被平移的板；把距离也算进来，
  /// 水滴才会像被手指拽住的橡皮：离落点越远，越细长。
  double _dragPull = 0;

  /// 最近一次有效拖动的方向：+1 向右、-1 向左。水滴的尾巴朝着来路。
  double _dragDirection = 1;

  /// 手指加速度（px/s²）：速度的瞬时变化，参与不规则拉伸。
  double _dragAcceleration = 0;

  /// 真实的指针速度采样：拖拽方向与甩动速度都从同一份轨迹读取。
  VelocityTracker _pointerVelocity = VelocityTracker.withKind(
    PointerDeviceKind.touch,
  );

  /// 上一次拖动采样的时间戳；为空或时间倒退时退化到「按 60fps 估计」。
  Duration? _lastDragStamp;

  @override
  void initState() {
    super.initState();
    _resolvedIndex = _indexOf(widget.activeId);
    _targetIndex = _resolvedIndex;
    _indexController = AnimationController.unbounded(
      vsync: this,
      value: _resolvedIndex.toDouble(),
    );
    _widthController = AnimationController.unbounded(vsync: this, value: 1);
    _pressController = AnimationController.unbounded(vsync: this, value: 0);
    _gripController = AnimationController.unbounded(vsync: this, value: 0);
    _dragTicker = createTicker(_onDragTick);
    _dropAnimation = Listenable.merge(<Listenable>[
      _indexController,
      _widthController,
      _pressController,
      _gripController,
      _pointerFocus,
    ]);
    // 弹簧的 isDone 有容差，落定时把值钉死在目标上，避免留下半个像素。
    _indexController.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_dragging) {
        _indexController.value = _targetIndex.toDouble();
      }
    });
    _widthController.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_dragging) {
        _widthController.value = 1;
      }
    });
    // 按压松手弹簧落定后把残差钉到 0，确保 sigma 回到设置值的精确值。
    _pressController.addStatusListener((status) {
      if (status == AnimationStatus.completed &&
          _pressController.value.abs() < .01) {
        _pressController.value = 0;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_motionEnabled) _stopMotion();
  }

  @override
  void didUpdateWidget(ShellDockBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = _indexOf(widget.activeId);
    if (index != _resolvedIndex) {
      _resolvedIndex = index;
      // 拖动中不改落点：手指还没松开，松手时自然会按当前位置重新吸附。
      if (!_dragging) _animateToIndex(index);
    }
    // 设置页把「点击弹跳动效」关掉后，正在飞的弹簧必须立刻停住并归位；
    // 不能等它自己弹完，否则设置与画面就不一致了。
    if (!widget.appearance.animateSelection &&
        oldWidget.appearance.animateSelection) {
      _stopMotion();
    }
  }

  /// 停止一切位移 / 宽度弹簧，直接落到当前已选页签。
  void _stopMotion() {
    _dragTicker.stop();
    _indexController.stop();
    _widthController.stop();
    _dragging = false;
    _dragVelocity = 0;
    _dragPull = 0;
    _pressController.stop();
    _pressController.value = 0;
    _pointerFocus.value = 0;
    _gripController.stop();
    _gripController.value = 0;
    _pressedPointer = null;
    _indexController.value = _resolvedIndex.toDouble();
    _widthController.value = 1;
  }

  @override
  void dispose() {
    _dragTicker.dispose();
    _indexController.dispose();
    _widthController.dispose();
    _pressController.dispose();
    _gripController.dispose();
    _pointerFocus.dispose();
    super.dispose();
  }

  /// 标识 → 下标；标识失效时退回上一个落点，绝不让下标越界。
  int _indexOf(String id) {
    if (widget.entries.isEmpty) return 0;
    final found = widget.entries.indexWhere((entry) => entry.id == id);
    if (found >= 0) return found;
    return _resolvedIndex.clamp(0, widget.entries.length - 1);
  }

  /// 上一次生成的水滴磨砂滤镜。AnimatedBuilder 每帧都会重建水滴，
  /// 按 sigma 缓存一份，避免每帧新建 [ImageFilter]。
  double? _cachedBlurSigma;
  ImageFilter? _cachedBlur;

  ImageFilter _blurFilter(double sigma) {
    if (_cachedBlur == null || _cachedBlurSigma != sigma) {
      _cachedBlurSigma = sigma;
      _cachedBlur = ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.mirror,
      );
    }
    return _cachedBlur!;
  }

  // ------------------------------------------------------------------ 手势

  void _onDragStart(DragStartDetails details, double slot) {
    if (widget.entries.isEmpty) return;
    _dragTicker.stop();
    _indexController.stop();
    _widthController.stop();
    _lastDragStamp = null;
    _dragVelocity = 0;
    _dragAcceleration = 0;
    final focus = _indexForX(details.localPosition.dx, slot);
    // 手指按下的位置就是水滴的新中心：像真的水珠被按过去一样跟手。
    _indexController.value = focus;
    _dragPull = _pullFor(focus);
    _dragDirection = focus >= _resolvedIndex ? 1 : -1;
    setState(() => _dragging = true);
    if (!_motionEnabled) {
      _widthController.value = 1;
      return;
    }
    _widthController.value = _widthScaleFor(0, _dragPull);
    if (!_dragTicker.isActive) _dragTicker.start();
  }

  void _onDragUpdate(DragUpdateDetails details, double slot) {
    if (widget.entries.isEmpty) return;
    _updateDragVelocity(details);
    // 核心跟手逻辑：localPosition.dx → 连续页签坐标，水滴中心贴着手指。
    final previous = _indexController.value;
    final focus = _indexForX(details.localPosition.dx, slot);
    if ((focus - previous).abs() > .001) {
      // 尾巴朝来路：向右拖时尾部在左，向左拖时尾部在右。
      _dragDirection = (focus - previous).sign;
    }
    _indexController.value = focus;
    _dragPull = _pullFor(focus);
    // 关掉「点击弹跳动效」时不再做拉伸；拖动仍然跟手，但松手直接瞬移。
    _widthController.value = _motionEnabled
        ? _widthScaleFor(_dragVelocity, _dragPull)
        : 1;
  }

  void _onDragEnd(DragEndDetails details, double slot) {
    _finishDrag(velocityPx: details.velocity.pixelsPerSecond.dx, slot: slot);
  }

  void _onDragCancel(double slot) {
    _dragTicker.stop();
    _dragVelocity = 0;
    _dragAcceleration = 0;
    _dragPull = 0;
    setState(() => _dragging = false);
    _animateToIndex(_resolvedIndex);
  }

  // ------------------------------------------------------------------ 按压 / 聚焦

  /// 指针位置 → 聚焦程度：越靠近页签中心（图标 / 文字），越清晰。
  double _focusForX(double x, double slot) {
    if (slot <= 0 || widget.entries.isEmpty) return 0;
    final index = ((x - slot / 2) / slot).round().clamp(
      0,
      widget.entries.length - 1,
    );
    final center = index * slot + slot / 2;
    // 图标 / 文字大约在槽位中心 40% 的范围内；边缘处聚焦为 0。
    final radius = math.min(slot * .42, 48.0);
    return (1 - (x - center).abs() / radius).clamp(0.0, 1.0);
  }

  /// 按下：从当前位置开始积累按压进度，停留越久越接近「按到底」。
  ///
  /// 时长仍从 [DockAppearance.animationMs] 推导，不新增第二套动效参数。
  void _onPressDown(PointerDownEvent event, double slot) {
    if (_pressedPointer != null) return;
    _pressedPointer = event.pointer;
    _pointerVelocity = VelocityTracker.withKind(PointerDeviceKind.touch)
      ..addPosition(event.timeStamp, event.position);
    _pointerFocus.value = _focusForX(event.localPosition.dx, slot);
    if (!_motionEnabled) {
      _pressController.stop();
      _pressController.value = 0;
      return;
    }
    final ms = _amount(DockLiquidParameter.pressMs).round();
    _updateGrip(event.localPosition.dy);
    final nearest = _indexForX(
      event.localPosition.dx,
      slot,
    ).round().clamp(0, widget.entries.length - 1);
    // Preview the touched tab while held; page selection is committed on up.
    _animateToIndex(nearest);
    // 有压感的设备用压力修正目标；没有压感（恒为 1 或 0）时按满。
    final pressure = event.pressure.isFinite && event.pressure > 0
        ? event.pressure.clamp(.35, 1.0)
        : 1.0;
    _pressController.animateTo(
      pressure,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
  }

  /// 手指在内容区移动：从页签边缘移到图标 / 文字上时，聚焦平滑上升。
  void _onPressMove(PointerMoveEvent event, double slot) {
    if (event.pointer != _pressedPointer) return;
    _pointerVelocity.addPosition(event.timeStamp, event.position);
    final tracked = _pointerVelocity.getVelocity().pixelsPerSecond.dx;
    if (tracked.abs() > 80) _dragDirection = tracked.sign;
    _pointerFocus.value = _focusForX(event.localPosition.dx, slot);
    if (_motionEnabled) _updateGrip(event.localPosition.dy);
  }

  void _updateGrip(double y) {
    final halfHeight = math.max(widget.appearance.height / 2, 1.0);
    final target = ((y - halfHeight) / halfHeight).clamp(-1.0, 1.0);
    _gripController.animateTo(
      target,
      duration: const Duration(milliseconds: 70),
      curve: Curves.easeOut,
    );
  }

  /// 松手：按压进度用当前弹簧参数弹回 0，水球带一点过冲恢复。
  void _releasePress() {
    _pressedPointer = null;
    _pointerFocus.value = 0;
    if (!_motionEnabled) {
      _pressController.stop();
      _pressController.value = 0;
      return;
    }
    _gripController.animateWith(
      SpringSimulation(_springDescription(), _gripController.value, 0, 0),
    );
    if (_pressController.value.abs() < .001) {
      _pressController.value = 0;
      return;
    }
    _pressController.animateWith(
      SpringSimulation(_springDescription(), _pressController.value, 0, 0),
    );
  }

  void _finishDrag({required double velocityPx, required double slot}) {
    _dragTicker.stop();
    _dragVelocity = 0;
    _dragAcceleration = 0;
    if (widget.entries.isEmpty) {
      setState(() => _dragging = false);
      return;
    }
    // 离手指最近的页签：用连续坐标四舍五入，而不是按拖动起点算。
    final nearest = _indexController.value.round().clamp(
      0,
      widget.entries.length - 1,
    );
    // 把松手速度换算成「页签/秒」，作为弹簧初速度：甩得越快，回弹越过
    // 目标越多，视觉上更像水被甩出去再被表面张力拉回来。
    final velocityIndex = slot <= 0
        ? 0.0
        : (velocityPx / slot).clamp(-10.0, 10.0);
    _dragPull = 0;
    if (!_motionEnabled) _widthController.value = 1;
    _selectIndex(nearest, velocity: velocityIndex);
  }

  /// 点击：页签自己的 [InkWell] 与底层 [GestureDetector.onTapUp] 都走这里。
  void _onTapUp(TapUpDetails details, double slot) {
    if (widget.entries.isEmpty || slot <= 0) return;
    // 点按不是拖动，按触点最近项吸附即可；不要求先落在水滴上。
    final nearest = ((details.localPosition.dx - slot / 2) / slot)
        .round()
        .clamp(0, widget.entries.length - 1);
    _selectIndex(nearest);
  }

  /// 页签自身的点按路径（保留 InkWell 的水波、语义与测试可点性）。
  void _onItemTap(int index) => _selectIndex(index);

  void _selectIndex(int index, {double velocity = 0}) {
    if (widget.entries.isEmpty) return;
    final target = index.clamp(0, widget.entries.length - 1);
    _dragPull = 0;
    setState(() {
      _dragging = false;
      _resolvedIndex = target;
    });
    _animateToIndex(target, velocity: velocity);
    widget.onSelect(widget.entries[target].id);
  }

  /// 手指位置 → 连续页签坐标。两端做夹取：水滴不会滑出内容区。
  double _indexForX(double x, double slot) {
    if (slot <= 0 || widget.entries.length <= 1) return 0;
    return (x - slot / 2) / slot;
  }

  /// 离最近页签中心的距离（0 = 正在中心，1 = 两页签之间）。
  ///
  /// 这是「慢慢拖也要有形变」的来源：只按速度算，手指停住水滴就会缩回去，
  /// 看起来像被平移的板；按距离算，它才像被橡皮筋拉住。
  double _pullFor(double focus) {
    final nearest = focus.roundToDouble();
    return ((focus - nearest).abs() * 2).clamp(0.0, 1.0);
  }

  /// 速度 + 拉力 → 宽度倍率：越快 / 离落点越远，拉得越长，但有上限。
  double _widthScaleFor(double velocityPx, double pull) {
    if (!_liquid.enabled(DockLiquidEffect.drag)) return 1;
    final speed = (velocityPx.abs() / 1800).clamp(0.0, 1.0);
    final tug = pull.clamp(0.0, 1.0);
    final accel = (_dragAcceleration.abs() / 12000).clamp(0.0, 1.0);
    final amount = math
        .max(speed, math.max(tug * .85, accel * .35))
        .clamp(0.0, 1.0);
    return 1 + amount * _amount(DockLiquidParameter.stretch);
  }

  void _updateDragVelocity(DragUpdateDetails details) {
    final stamp = details.sourceTimeStamp;
    final previous = _lastDragStamp;
    if (stamp != null && previous != null && stamp > previous) {
      final seconds =
          (stamp - previous).inMicroseconds / Duration.microsecondsPerSecond;
      if (seconds > 0) {
        final instant = details.delta.dx / seconds;
        final previousVelocity = _dragVelocity;
        // 指数平滑：单帧抖动不会让水滴突然抽搐。
        _dragVelocity = _dragVelocity == 0
            ? instant
            : _dragVelocity * .65 + instant * .35;
        final instantAccel = (instant - previousVelocity) / seconds;
        _dragAcceleration = _dragAcceleration == 0
            ? instantAccel
            : _dragAcceleration * .7 + instantAccel * .3;
        _lastDragStamp = stamp;
        return;
      }
    }
    // 无时间戳（或被合并成一帧）：按 60fps 估计，保证仍然有拉伸反馈。
    final estimated = details.delta.dx * 60;
    final previousVelocity = _dragVelocity;
    _dragVelocity = _dragVelocity == 0
        ? estimated
        : _dragVelocity * .65 + estimated * .35;
    final instantAccel = (estimated - previousVelocity) * 60;
    _dragAcceleration = _dragAcceleration == 0
        ? instantAccel
        : _dragAcceleration * .7 + instantAccel * .3;
    _lastDragStamp = stamp;
  }

  /// 手指停住时速度衰减；只要还离落点有距离，就保留被拉长的余量。
  void _onDragTick(Duration _) {
    if (!_dragging || !_motionEnabled) {
      _dragTicker.stop();
      _widthController.value = 1;
      return;
    }
    _dragVelocity *= .86;
    _dragAcceleration *= .86;
    if (_dragVelocity.abs() < 24) _dragVelocity = 0;
    _widthController.value = _widthScaleFor(_dragVelocity, _dragPull);
    if (_dragVelocity == 0 && _dragPull == 0) _dragTicker.stop();
  }

  // ------------------------------------------------------------------ 弹簧

  /// 设置里的 [DockAppearance.animationMs] 是「吸附过程大概多久」：
  /// 用它换算弹簧刚度（周期与 1/√k 成正比），时长越长弹簧越软；阻尼按固定
  /// 阻尼比换算成显式的 damping 值，水珠才会过冲一点点再回来。
  SpringDescription _springDescription() {
    final ms = widget.appearance.animationMs.clamp(100, 2000);
    final period = (ms / 1000) * .56;
    final stiffness = math.pow((2 * math.pi) / period, 2).toDouble();
    final damping =
        2 * _amount(DockLiquidParameter.damping) * math.sqrt(stiffness);
    return SpringDescription(mass: 1, stiffness: stiffness, damping: damping);
  }

  /// 把水滴弹到第 [index] 个页签中心。
  ///
  /// 两个独立弹簧：
  /// - [_indexController]：连续坐标 → 目标下标，带松手速度；
  /// - [_widthController]：被拉长的宽度 → 1，回到基准宽度。
  ///
  /// 分开弹而不是套一个 Tween：宽度和位移的初始速度不同，合成一个补间会
  /// 让「水滴先缩回再走」或「先走到再缩回」，两种都不像水。
  void _animateToIndex(int index, {double velocity = 0}) {
    _targetIndex = index;
    final target = index.toDouble();
    final from = _indexController.value;
    final widthFrom = _widthController.value;
    final animate = _motionEnabled;

    if (!animate) {
      _indexController.stop();
      _widthController.stop();
      _indexController.value = target;
      _widthController.value = 1;
      return;
    }

    // 已经停在目标而且没有被拉长：不需要再起一次弹簧。
    if ((from - target).abs() < .001 &&
        (widthFrom - 1).abs() < .001 &&
        velocity.abs() < 1) {
      _indexController.value = target;
      _widthController.value = 1;
      return;
    }

    final spring = _springDescription();
    _indexController.animateWith(
      SpringSimulation(spring, from, target, velocity),
    );
    _widthController.animateWith(SpringSimulation(spring, widthFrom, 1, 0));
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: FloatingModules.instance,
    builder: (context, _) {
      final style = FloatingModules.instance.style(FloatingModule.dock);
      final dark = LumeTheme.palette.brightness == Brightness.dark;
      final layoutBottom = math.max(widget.bottomMargin, 0.0);
      final sink = math.max(-widget.bottomMargin, 0.0);
      return Transform.translate(
        offset: Offset(style.x, style.y),
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: ExcludeSemantics(
            excluding: !widget.visible,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final safe = widget.applyViewPadding
                    ? MediaQuery.viewPaddingOf(context)
                    : EdgeInsets.zero;
                return AnimatedSlide(
                  offset: widget.visible ? Offset.zero : const Offset(0, 1.2),
                  duration: _motionEnabled
                      ? const Duration(milliseconds: 180)
                      : Duration.zero,
                  curve: Curves.easeOut,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      widget.appearance.horizontalMargin + safe.left,
                      0,
                      widget.appearance.horizontalMargin + safe.right,
                      layoutBottom,
                    ),
                    child: Transform.translate(
                      offset: Offset(0, sink),
                      child: _buildCapsule(style, dark),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    },
  );

  double? _cachedCapsuleSigma;
  ImageFilter? _cachedCapsuleFilter;

  Widget _buildCapsule(FloatingStyle style, bool dark) => SizedBox(
    height: widget.capsuleHeight,
    child: AnimatedBuilder(
      animation: _dropAnimation,
      builder: (context, _) {
        final press = _motionEnabled
            ? _pressController.value.clamp(0.0, 1.0)
            : 0.0;
        final rebound = _motionEnabled
            ? math.max(-_pressController.value, 0.0)
            : 0.0;
        final stretch = _stretchFraction;
        final capsule = _liquid.enabled(DockLiquidEffect.capsule) ? 1.0 : 0.0;
        final clear = _liquid.enabled(DockLiquidEffect.clarity) ? press : 0.0;
        final light = _liquid.enabled(DockLiquidEffect.lighting) ? press : 0.0;
        final gain = _amount(DockLiquidParameter.highlight) * light;
        final grip = _gripController.value.clamp(-1.0, 1.0);
        final focus = widget.entries.length <= 1
            ? 0.0
            : (_indexController.value / (widget.entries.length - 1) * 2 - 1)
                  .clamp(-1.0, 1.0);
        final radius = BorderRadius.circular(widget.capsuleHeight / 2);
        final borderAlpha = _borderAlpha(dark);
        final glassColor = dark ? LumeTheme.glass : Colors.white;
        // Blur the original page once here, before painting the floating drop.
        // A second filter inside already-blurred glass cannot restore detail.
        final sigma =
            style.blur *
            (1 - _amount(DockLiquidParameter.blurReduction) * clear);
        if (_cachedCapsuleFilter == null || _cachedCapsuleSigma != sigma) {
          _cachedCapsuleSigma = sigma;
          _cachedCapsuleFilter = ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.mirror,
          );
        }
        // Preserve both slider endpoints: 0 stays transparent; 1 stays opaque.
        final opacity =
            style.opacity *
            (1 -
                _amount(DockLiquidParameter.opacityReduction) *
                    clear *
                    (1 - style.opacity));
        final dropOpacity = (style.opacity * 1.35).clamp(0.0, 1.0);
        final transform = Matrix4.identity()
          ..setEntry(
            0,
            0,
            1 +
                capsule *
                    _amount(DockLiquidParameter.capsuleX) *
                    (press + .35 * stretch - .55 * rebound),
          )
          ..setEntry(
            1,
            1,
            1 +
                capsule *
                    _amount(DockLiquidParameter.capsuleY) *
                    (press - .38 * stretch - .38 * rebound),
          )
          ..setEntry(0, 1, .012 * grip * press * capsule)
          ..setTranslationRaw(
            focus * press * 1.5 * capsule,
            grip * press * 1.2 * capsule,
            0,
          );
        final sheen = style.opacity * (dark ? .22 : .44);
        return Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            // Only this surface is clipped. The droplet, optical layer and
            // their shadows can rise above and below the base capsule.
            Positioned.fill(
              child: IgnorePointer(
                child: Transform(
                  key: ShellDockBar.capsuleSurfaceKey,
                  alignment: Alignment.center,
                  transform: transform,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha:
                                (widget.appearance.shadowOpacity *
                                        (1 +
                                            light *
                                                _amount(
                                                  DockLiquidParameter.shadow,
                                                ) /
                                                2.2))
                                    .clamp(0.0, 1.0),
                          ),
                          blurRadius: 20 + 4 * light,
                          offset: Offset(0, 6 + 2 * light),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: radius,
                      child: BackdropFilter(
                        key: ShellDockBar.capsuleFilterKey,
                        filter: _cachedCapsuleFilter!,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: glassColor.withValues(alpha: opacity),
                            borderRadius: radius,
                            border: Border.all(
                              color: Colors.white.withValues(
                                alpha: (borderAlpha * (1 + gain * .58)).clamp(
                                  0.0,
                                  1.0,
                                ),
                              ),
                            ),
                            gradient: LinearGradient(
                              begin: Alignment(-.25 * focus, -1),
                              end: Alignment(.25 * focus, 1),
                              colors: [
                                Colors.white.withValues(
                                  alpha: (sheen * (1 + gain * .5)).clamp(
                                    0.0,
                                    .42,
                                  ),
                                ),
                                Colors.white.withValues(alpha: 0),
                                Colors.white.withValues(
                                  alpha: (style.opacity * .10).clamp(0.0, .12),
                                ),
                              ],
                              stops: const [0, .55, 1],
                            ),
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(bottom: widget.contentInset),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: ShellDockBar.innerPadding,
                ),
                child: _buildContent(
                  verticalPadding: ((widget.appearance.height - 42) / 2).clamp(
                    2.0,
                    10.0,
                  ),
                  dropFill: glassColor.withValues(
                    alpha:
                        (dropOpacity *
                                (1 -
                                    _amount(
                                          DockLiquidParameter.opacityReduction,
                                        ) *
                                        1.875 *
                                        clear *
                                        (1 - dropOpacity)))
                            .clamp(0.0, 1.0),
                  ),
                  dropBlurSigma: style.blur,
                  dropBorder: Colors.white.withValues(
                    alpha: (borderAlpha * (1 + gain)).clamp(0.0, 1.0),
                  ),
                  whiteGlow: (style.opacity * (.40 + .20 * gain)).clamp(
                    0.0,
                    .65,
                  ),
                  accentGlow: (style.opacity * .26).clamp(0.0, .35),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _buildContent({
    required double verticalPadding,
    required Color dropFill,
    required double dropBlurSigma,
    required Color dropBorder,
    required double whiteGlow,
    required double accentGlow,
  }) {
    final entries = widget.entries;

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth;
        if (entries.isEmpty) return const SizedBox.expand();

        final slot = contentWidth / entries.length;
        final baseWidth = (slot - 12).clamp(0.0, ShellDockBar.maxPillWidth);
        final dropHeight = (constraints.maxHeight - ShellDockBar._dropInset * 2)
            .clamp(0.0, double.infinity);
        final dropRadius = BorderRadius.circular(dropHeight / 2);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 拖动过程中每一步都用 localPosition.dx 重算水滴中心；
          // 速度只影响宽度，不改变「水滴贴着手指」这条主逻辑。
          onHorizontalDragStart: (details) => _onDragStart(details, slot),
          onHorizontalDragUpdate: (details) => _onDragUpdate(details, slot),
          onHorizontalDragEnd: (details) => _onDragEnd(details, slot),
          onHorizontalDragCancel: () => _onDragCancel(slot),
          // 覆盖页签之间的空隙；页签自身的 InkWell 仍保留点击语义。
          onTapUp: (details) => _onTapUp(details, slot),
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) => _onPressDown(event, slot),
            onPointerMove: (event) => _onPressMove(event, slot),
            onPointerUp: (event) {
              if (event.pointer == _pressedPointer) _releasePress();
            },
            onPointerCancel: (event) {
              if (event.pointer != _pressedPointer) return;
              _releasePress();
              _animateToIndex(_resolvedIndex);
            },
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _dropAnimation,
                builder: (context, _) {
                  // 水滴中心始终取连续坐标：拖动时它等于手指位置，松手后由弹簧
                  // 一帧帧推到目标中心，不能在松手瞬间直接换成整数下标。
                  final indexFocus = _indexController.value.clamp(
                    0.0,
                    (entries.length - 1).toDouble(),
                  );
                  final activeIndex =
                      (_dragging || _pressedPointer != null
                              ? indexFocus.round()
                              : _resolvedIndex)
                          .clamp(0, entries.length - 1);

                  // 按压进度与指针位置共同决定「擦亮玻璃」的程度：
                  // - 按住不放：press 从 0 → 1，sigma 逐渐降低；
                  // - 从页签边缘移到图标 / 文字：pointerFocus 平滑升高。
                  // 基础 sigma 始终来自当前的 FloatingStyle.blur，不写死。
                  final pressRaw = _pressController.value.clamp(-.18, 1.0);
                  final press = pressRaw.clamp(0.0, 1.0);
                  final lift = _liquid.enabled(DockLiquidEffect.lift)
                      ? press
                      : 0.0;
                  final grip = _liquid.enabled(DockLiquidEffect.lift)
                      ? _gripController.value.clamp(-1.0, 1.0)
                      : 0.0;
                  final clear = _liquid.enabled(DockLiquidEffect.clarity)
                      ? 1.0
                      : 0.0;
                  final pointerFocus =
                      (press * (.45 + .55 * _pointerFocus.value)).clamp(
                        0.0,
                        1.0,
                      );
                  final sigma =
                      (dropBlurSigma *
                              (1 -
                                  pointerFocus *
                                      clear *
                                      (_amount(
                                                DockLiquidParameter
                                                    .blurReduction,
                                              ) /
                                              .62 *
                                              .66)
                                          .clamp(0.0, 1.0)))
                          .clamp(0.0, dropBlurSigma);
                  final dropFilter = _blurFilter(sigma);

                  // 水珠宽度 = 基准宽度 × 速度/拉力倍率 + 按压膨胀；夹取只防极端值。
                  // 基准宽度来自当前留白 / 页签数量；按压膨胀量按当前高度比例
                  // 计算——拉动「导航栏高度」滑块时，膨胀幅度会一起变化。
                  final pressBulge =
                      dropHeight *
                      _amount(DockLiquidParameter.spread) *
                      (_liquid.enabled(DockLiquidEffect.lift) ? pressRaw : 0.0);
                  final dropWidth =
                      (baseWidth * _widthController.value + pressBulge).clamp(
                        baseWidth * .75,
                        contentWidth,
                      );
                  // 形变量 0–1：宽度倍率 1–1.65 映射回液体路径的「拉长程度」。
                  final stretch = _stretchFraction;
                  final raisedHeight =
                      dropHeight *
                      (1 +
                          _amount(DockLiquidParameter.lift) * lift -
                          .08 * stretch);
                  final top =
                      ShellDockBar._dropInset -
                      (raisedHeight - dropHeight) / 2 +
                      grip * dropHeight * _amount(DockLiquidParameter.vertical);
                  final lean = _dragDirection * stretch;
                  // 中心跟着连续坐标走，left 永远 = 中心 - 半宽（橡皮筋拉伸时
                  // 向两侧同时长，而不是只向右长）。
                  final center = indexFocus * slot + slot / 2;
                  final maxLeft = (contentWidth - dropWidth).clamp(
                    0.0,
                    double.infinity,
                  );
                  final edgeGive = press * dropHeight * .16;
                  final left = (center - dropWidth / 2).clamp(
                    -edgeGive,
                    maxLeft + edgeGive,
                  );

                  return Stack(
                    clipBehavior: Clip.none,
                    fit: StackFit.expand,
                    children: <Widget>[
                      // 先给背景做磨砂与底色，文字不参与这一步模糊。
                      Positioned(
                        left: left,
                        top: top,
                        width: dropWidth,
                        height: raisedHeight,
                        child: IgnorePointer(
                          child: RepaintBoundary(
                            child: _WaterDrop(
                              key: ShellDockBar.selectionPillKey,
                              radius: dropRadius,
                              fill: dropFill,
                              filter: dropFilter,
                              border: dropBorder,
                              whiteGlow: whiteGlow,
                              accentGlow: accentGlow,
                              stretch: stretch,
                              press: pressRaw,
                              direction: _dragDirection,
                              grip: grip,
                              tail: _amount(DockLiquidParameter.tail),
                              shadowOpacity:
                                  (widget.appearance.shadowOpacity *
                                          press *
                                          (_liquid.enabled(
                                                DockLiquidEffect.lighting,
                                              )
                                              ? _amount(
                                                  DockLiquidParameter.shadow,
                                                )
                                              : 0))
                                      .clamp(0.0, .45),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (var index = 0; index < entries.length; index++)
                            Expanded(
                              child: _DockItem(
                                entry: entries[index],
                                selected: index == activeIndex,
                                onTap: () => _onItemTap(index),
                                verticalPadding: verticalPadding,
                                animateSelection: _motionEnabled,
                                animationDuration: Duration(
                                  milliseconds: widget.appearance.animationMs,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (_liquid.enabled(DockLiquidEffect.optics))
                        Positioned(
                          left: left,
                          top: top,
                          width: dropWidth,
                          height: raisedHeight,
                          child: DockLiquidLens(
                            path: _liquidDropPath(
                              Size(dropWidth, raisedHeight),
                              stretch: stretch,
                              press: pressRaw,
                              direction: _dragDirection,
                              grip: grip,
                              tail: _amount(DockLiquidParameter.tail),
                            ),
                            press: pressRaw,
                            stretch: stretch,
                            highlight: widget.appearance.borderOpacity,
                            lean: lean,
                            grip: grip,
                            refraction: _amount(DockLiquidParameter.refraction),
                            dispersion: _amount(DockLiquidParameter.dispersion),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// 深色主题下把边框强度按比例柔化：白色 1px 在暗底上比亮底醒目得多。
  double _borderAlpha(bool dark) {
    return dark
        ? widget.appearance.borderOpacity * 0.44
        : widget.appearance.borderOpacity;
  }
}

/// 毛玻璃水滴：拖动时是橡皮筋，静止时是一颗贴在玻璃上的水珠。
///
/// 材质不是写死的：填充色与磨砂强度来自 [FloatingStyle] 的 dock 样式（玻璃
/// 白度 / 磨砂强度），边框来自 [DockAppearance.borderOpacity]（边缘高光）。
/// 它叠在外层 Dock 玻璃之上，所以背后的颜色会先被外层磨砂一次、再被水滴轻磨
/// 一次——选中底座才有「一滴水」的体积感，而不是一块纯色圆角矩形。
class _WaterDrop extends StatelessWidget {
  const _WaterDrop({
    super.key,
    required this.radius,
    required this.fill,
    required this.filter,
    required this.border,
    required this.whiteGlow,
    required this.accentGlow,
    required this.stretch,
    required this.press,
    required this.direction,
    required this.grip,
    required this.shadowOpacity,
    required this.tail,
  });

  final BorderRadius radius;

  /// 与 Dock 相同的半透明白底（白度设置）。
  final Color fill;

  /// 与 Dock 相同的磨砂强度（磨砂设置）。
  final ImageFilter filter;

  /// 1px 白边（边缘高光设置）。
  final Color border;

  /// 白色 / 主题色外发光，强度跟随白度，白度 0 时一起消失。
  final double whiteGlow;
  final double accentGlow;

  /// 0 = 静止的胶囊，1 = 被拉到最长：尾部收窄、整体轻微压扁。
  final double stretch;

  /// 按压进度：0 = 未按，1 = 按到底；松手弹簧会短暂越过 0（负值）再回正。
  final double press;

  /// 拖动方向：+1 向右、-1 向左；尾巴朝着来路。
  final double direction;
  final double grip, shadowOpacity, tail;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final path = _liquidDropPath(
          size,
          stretch: stretch,
          press: press,
          direction: direction,
          grip: grip,
          tail: tail,
        );
        return DecoratedBox(
          // 外发光模拟水珠边缘的折射：不额外加底色，纯光晕。
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: <BoxShadow>[
              if (shadowOpacity > 0)
                BoxShadow(
                  color: Colors.black.withValues(alpha: shadowOpacity),
                  blurRadius: 10 + 6 * press.clamp(0.0, 1.0),
                  offset: Offset(0, 3 + 3 * press.clamp(0.0, 1.0)),
                ),
              if (whiteGlow > 0)
                BoxShadow(
                  color: Colors.white.withValues(alpha: whiteGlow),
                  blurRadius: 12,
                  spreadRadius: -4,
                  offset: const Offset(0, 1),
                ),
              if (accentGlow > 0)
                BoxShadow(
                  color: LumeTheme.accent.withValues(alpha: accentGlow),
                  blurRadius: 18,
                  spreadRadius: -6,
                  offset: const Offset(0, 5),
                ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 形状不是圆角矩形：拖动时是一条带尾巴的水滴路径，磨砂与白度
              // 仍然来自设置，边缘高光用同一路径描边。
              ClipPath(
                clipper: _LiquidDropClipper(path),
                child: BackdropFilter(
                  filter: filter,
                  child: ColoredBox(color: fill),
                ),
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _LiquidDropBorderPainter(path: path, color: border),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 把静止胶囊与拖动中的水滴统一成一条路径。
///
/// [stretch] 为 0 时精确退化成圆角胶囊；大于 0 时尾端半径收窄、上下缘轻微
/// 外鼓，并把高度压扁一点，形成「被手指拽住的水滴」而不是一块被拉宽的板。
Path _liquidDropPath(
  Size size, {
  required double stretch,
  required double press,
  required double direction,
  double grip = 0,
  double tail = .55,
}) {
  final t = stretch.clamp(0.0, 1.0);
  final p = press.clamp(-.18, 1.0);
  final pressed = p.clamp(0.0, 1.0);
  final rebound = math.max(-p, 0.0);
  if (size.width <= 0 || size.height <= 0) return Path();
  // The positioned layer already includes the press lift; do not flatten it.
  final h = size.height * (1 - .06 * t + .04 * rebound);
  final top = (size.height - h) / 2;
  final w = size.width;
  if (w < h) {
    // Tall bars and narrow slots must not create intersecting semicircles.
    return Path()..addOval(Rect.fromLTWH(0, top, w, h));
  }
  final r = h / 2;
  final tipR = r * (1 - tail * t + .08 * pressed);
  final tipX = tipR;
  final right = math.max(tipR + .01, w - r);
  const kappa = .5522847498;

  final path = Path()
    ..moveTo(right, top)
    // 前缘：完整的半圆（手指前进的方向）。
    ..cubicTo(right + r * kappa, top, w, top + r - r * kappa, w, top + r)
    ..cubicTo(
      w,
      top + r + r * kappa,
      right + r * kappa,
      top + h,
      right,
      top + h,
    );

  // 下缘：向尾部收窄，中段轻微外鼓（水的体积感）。
  final bulge = r * (.10 * t + .06 * pressed);
  final verticalGrip = grip.clamp(-1.0, 1.0) * r * .12 * pressed;
  path.cubicTo(
    right - (right - tipX) * .38,
    top + h + bulge + verticalGrip,
    tipX + (right - tipX) * .28,
    top + r + tipR + bulge * .35 + verticalGrip,
    tipX,
    top + r + tipR,
  );

  // 尾端：半径随拉力变小的半圆。
  final kt = kappa * tipR;
  path
    ..cubicTo(
      tipX - kt,
      top + r + tipR,
      tipX - tipR,
      top + r + kt,
      tipX - tipR,
      top + r,
    )
    ..cubicTo(
      tipX - tipR,
      top + r - kt,
      tipX - kt,
      top + r - tipR,
      tipX,
      top + r - tipR,
    );

  // 上缘：回到前缘。
  path.cubicTo(
    tipX + (right - tipX) * .28,
    top + r - tipR - bulge * .35 + verticalGrip,
    right - (right - tipX) * .38,
    top - bulge + verticalGrip,
    right,
    top,
  );
  path.close();

  if (direction < 0) {
    final mirror = Matrix4.identity()
      ..setEntry(0, 0, -1)
      ..setEntry(0, 3, w);
    return path.transform(mirror.storage);
  }
  return path;
}

class _LiquidDropClipper extends CustomClipper<Path> {
  const _LiquidDropClipper(this.path);

  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(_LiquidDropClipper oldClipper) =>
      !identical(oldClipper.path, path);
}

class _LiquidDropBorderPainter extends CustomPainter {
  const _LiquidDropBorderPainter({required this.path, required this.color});

  final Path path;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a <= 0) return;
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_LiquidDropBorderPainter oldDelegate) =>
      !identical(oldDelegate.path, path) || oldDelegate.color != color;
}

/// 单个页签：图标 + 文案，颜色随选中态平滑过渡。
class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.verticalPadding,
    required this.animateSelection,
    required this.animationDuration,
  });

  final ShellDockEntry entry;
  final bool selected;
  final VoidCallback onTap;

  /// 上下内边距：由 Dock 高度反推（40–150 档位里保持内容居中）。
  final double verticalPadding;

  /// 设置页的「点击弹跳动效」开关；关闭时所有过渡时长归零（立即切换）。
  final bool animateSelection;

  /// 选中水滴 / 图标 / 文字过渡时长（设置页可调，100–2000ms）。
  final Duration animationDuration;

  /// 实际生效的时长：关掉动效时直接跳到终态。
  Duration get _selectionDuration =>
      animateSelection ? animationDuration : Duration.zero;

  /// 图标槽固定高度（选中图标 20 + 上下各 1 = 22）。
  static const double _iconSlot = 22;

  @override
  Widget build(BuildContext context) {
    final color = selected ? LumeTheme.accent : LumeTheme.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPadding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            SizedBox(
              height: _iconSlot,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  // 图标：颜色平滑过渡，实心 / 线框之间交叉淡入；选中时轻微放大，
                  // 给滑动水滴一个落点反馈（水滴负责位移，图标只负责「弹」）。
                  TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: color),
                    duration: _selectionDuration,
                    curve: Curves.easeInOut,
                    builder: (context, animatedColor, _) => AnimatedScale(
                      scale: selected ? 1.06 : 1,
                      duration: _selectionDuration,
                      curve: selected ? Curves.easeOutBack : Curves.easeIn,
                      child: AnimatedSwitcher(
                        duration: _selectionDuration,
                        switchInCurve: Curves.easeOutBack,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, animation) =>
                            ScaleTransition(
                              scale: Tween<double>(
                                begin: .8,
                                end: 1,
                              ).animate(animation),
                              child: FadeTransition(
                                opacity: animation,
                                child: child,
                              ),
                            ),
                        child: LumeIcon(
                          selected ? entry.selectedIcon : entry.icon,
                          slot:
                              'dock.${entry.id}.${selected ? 'selected' : 'normal'}',
                          label: '${entry.label} · ${selected ? '选中' : '未选中'}',
                          group: '底部导航',
                          key: ValueKey<bool>(selected),
                          size: 20,
                          color: animatedColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 高度收到 40pt 时剩余空间不足以放下整行文字：Flexible 先让出
            // 可用高度，FittedBox 再等比缩小，杜绝 RenderFlex overflow。
            // 默认 54pt 档位空间足够，字号仍是 captionSize，不会被缩放。
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: color),
                  duration: _selectionDuration,
                  curve: Curves.easeInOut,
                  builder: (context, animatedColor, _) => Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: LumeTypography.captionSize,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: animatedColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
