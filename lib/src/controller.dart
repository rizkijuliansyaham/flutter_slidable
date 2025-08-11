import 'package:flutter/widgets.dart';

const _defaultMovementDuration = Duration(milliseconds: 200);
const _defaultCurve = Curves.ease;

enum ActionPaneType { end, none, start }
enum GestureDirection { opening, closing }

abstract class RatioConfigurator {
  double normalizeRatio(double ratio);
  double get extentRatio;
  void handleEndGestureChanged();
}

@immutable
class ResizeRequest {
  const ResizeRequest(this.duration, this.onDismissed);
  final Duration duration;
  final VoidCallback onDismissed;
}

@immutable
class DismissGesture {
  const DismissGesture(this.endGesture);
  final EndGesture? endGesture;
}

@immutable
class EndGesture {
  const EndGesture(this.velocity);
  final double velocity;
}

class OpeningGesture extends EndGesture {
  const OpeningGesture(double velocity) : super(velocity);
}

class ClosingGesture extends EndGesture {
  const ClosingGesture(double velocity) : super(velocity);
}

class StillGesture extends EndGesture {
  const StillGesture(this.direction) : super(0);
  final GestureDirection direction;
  bool get opening => direction == GestureDirection.opening;
  bool get closing => direction == GestureDirection.closing;
}

class SlidableController {
  static final List<SlidableController> _controllers = [];

  SlidableController(
    TickerProvider vsync, {
    this.onFullyExtended,
    this.fullWidthDuration = const Duration(milliseconds: 300),
    this.fullWidthDelay = const Duration(milliseconds: 500),
    this.snapBackThresholdRatio = 0.5,
    this.allowFullWidthBeyondExtentRatio = false,
  })  : assert(snapBackThresholdRatio >= 0 && snapBackThresholdRatio <= 1),
        _animationController = AnimationController(vsync: vsync),
        endGesture = ValueNotifier<EndGesture?>(null),
        _dismissGesture = _ValueNotifier<DismissGesture?>(null),
        resizeRequest = ValueNotifier<ResizeRequest?>(null),
        actionPaneType = ValueNotifier<ActionPaneType>(ActionPaneType.none),
        direction = ValueNotifier<int>(0) {
    direction.addListener(_onDirectionChanged);
    _controllers.add(this);
    _animationController.addListener(_onAnimationChanged);
  }

  final VoidCallback? onFullyExtended;
  final Duration fullWidthDuration;
  final Duration fullWidthDelay;

  final double snapBackThresholdRatio;            
  final bool allowFullWidthBeyondExtentRatio;     

  bool _hasCalledFullyExtended = false;
  bool _isInFullWidthAnimation = false;
  bool _isClosingOthers = false;
  final AnimationController _animationController;
  final _ValueNotifier<DismissGesture?> _dismissGesture;

  bool enableStartActionPane = true;
  bool enableEndActionPane = true;
  bool isLeftToRight = true;

  double _startActionPaneExtentRatio = 0.0;
  double _endActionPaneExtentRatio = 0.0;

  RatioConfigurator? _actionPaneConfigurator;
  RatioConfigurator? get actionPaneConfigurator => _actionPaneConfigurator;
  set actionPaneConfigurator(RatioConfigurator? value) {
    if (_actionPaneConfigurator != value) {
      _actionPaneConfigurator = value;
      if (_replayEndGesture && value != null) {
        _replayEndGesture = false;
        value.handleEndGestureChanged();
      }
    }
  }

  bool _replayEndGesture = false;
  Animation<double> get animation => _animationController.view;
  final ValueNotifier<EndGesture?> endGesture;
  ValueNotifier<DismissGesture?> get dismissGesture => _dismissGesture;
  final ValueNotifier<ResizeRequest?> resizeRequest;
  final ValueNotifier<ActionPaneType> actionPaneType;
  final ValueNotifier<int> direction;
  bool _closing = false;
  bool get closing => _closing;
  bool get isDismissibleReady => _dismissGesture._hasListeners;

  bool _acceptRatio(double ratio) {
    return !_closing &&
        (ratio == 0 ||
         ((ratio > 0 && enablePositiveActionPane) ||
          (ratio < 0 && enableNegativeActionPane)));
  }

  bool get enablePositiveActionPane =>
      isLeftToRight ? enableStartActionPane : enableEndActionPane;
  bool get enableNegativeActionPane =>
      isLeftToRight ? enableEndActionPane : enableStartActionPane;

  double get startActionPaneExtentRatio => _startActionPaneExtentRatio;
  set startActionPaneExtentRatio(double value) {
    if (value >= 0 && value <= 1) _startActionPaneExtentRatio = value;
  }

  double get endActionPaneExtentRatio => _endActionPaneExtentRatio;
  set endActionPaneExtentRatio(double value) {
    if (value >= 0 && value <= 1) _endActionPaneExtentRatio = value;
  }

  double get ratio => _animationController.value * direction.value;
  set ratio(double value) {
    final double newRatio =
        _actionPaneConfigurator?.normalizeRatio(value) ?? value;
    final double extent = _actionPaneConfigurator?.extentRatio ?? 0.0;
    final double clamped = allowFullWidthBeyondExtentRatio
        ? newRatio.clamp(-1.0, 1.0)
        : newRatio.clamp(-extent, extent);

    if (_acceptRatio(clamped) && clamped != ratio) {
      direction.value = clamped.sign.toInt();
      _animationController.value = clamped.abs();
    }
  }

  bool get isExtended => _animationController.value > 0.0;
  bool get isClosed => _animationController.value == 0.0;
  bool get isFullyExtended {
    final double extent = _actionPaneConfigurator?.extentRatio ?? 0.0;
    return extent > 0.0 &&
        _animationController.value >= extent - 0.01;
  }

  void _onAnimationChanged() {
    if (_isClosingOthers || _isInFullWidthAnimation) return;
    final bool fully = isFullyExtended;

    if (fully && !_hasCalledFullyExtended && onFullyExtended != null) {
      _hasCalledFullyExtended = true;
      _animateToFullWidthThenClose();
    }

    if (!fully) _hasCalledFullyExtended = false;

    if (fully && !_closing && !_isInFullWidthAnimation) _closeOtherControllers();
  }

  Future<void> _animateToFullWidthThenClose() async {
    if (_isInFullWidthAnimation || _closing) return;
    _isInFullWidthAnimation = true;
    try {
      onFullyExtended?.call();
      await _animationController.animateTo(
        1.0,
        duration: fullWidthDuration,
        curve: Curves.easeOut,
      );
      await Future.delayed(fullWidthDelay);
      await close(duration: fullWidthDuration, curve: Curves.easeIn);
    } finally {
      _isInFullWidthAnimation = false;
    }
  }

  void _closeOtherControllers() {
    _isClosingOthers = true;
    for (final c in _controllers) {
      if (c != this && c.isExtended && !c._closing) c._closeImmediately();
    }
    _isClosingOthers = false;
  }

  void _closeImmediately() {
    _animationController.value = 0.0;
    direction.value = 0;
    _hasCalledFullyExtended = false;
    _isInFullWidthAnimation = false;
  }

  void _onDirectionChanged() {
    final int m = isLeftToRight ? 1 : -1;
    final int idx = (direction.value * m) + 1;
    actionPaneType.value = ActionPaneType.values[idx];
  }

  void dispatchEndGesture(double? velocity, GestureDirection direction) {
    if (velocity == null || velocity == 0) {
      endGesture.value = StillGesture(direction);
    } else if (velocity.sign == this.direction.value) {
      endGesture.value = OpeningGesture(velocity);
    } else {
      endGesture.value = ClosingGesture(velocity.abs());
    }

    final double extent = _actionPaneConfigurator?.extentRatio ?? 0.0;
    final double progress = _animationController.value;
    if (extent > 0.0) {
      if (progress < extent * snapBackThresholdRatio) {
        close(duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      } else {
        openCurrentActionPane(
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    } else if (_actionPaneConfigurator == null) {
      _replayEndGesture = true;
    }
  }

  Future<void> close(
      {Duration duration = _defaultMovementDuration,
      Curve curve = _defaultCurve}) async {
    _closing = true;
    _isInFullWidthAnimation = false;
    await _animationController.animateBack(0.0, duration: duration, curve: curve);
    direction.value = 0;
    _hasCalledFullyExtended = false;
    _closing = false;
  }

  Future<void> openCurrentActionPane(
          {Duration duration = _defaultMovementDuration,
          Curve curve = _defaultCurve}) =>
      openTo(_actionPaneConfigurator!.extentRatio,
          duration: duration, curve: curve);

  Future<void> openStartActionPane(
          {Duration duration = _defaultMovementDuration,
          Curve curve = _defaultCurve}) async {
    if (actionPaneType.value != ActionPaneType.start) {
      direction.value = isLeftToRight ? 1 : -1;
      ratio = 0.0;
    }
    return openTo(startActionPaneExtentRatio,
        duration: duration, curve: curve);
  }

  Future<void> openEndActionPane(
          {Duration duration = _defaultMovementDuration,
          Curve curve = _defaultCurve}) async {
    if (actionPaneType.value != ActionPaneType.end) {
      direction.value = isLeftToRight ? -1 : 1;
      ratio = 0.0;
    }
    return openTo(-endActionPaneExtentRatio,
        duration: duration, curve: curve);
  }

  Future<void> openTo(double targetRatio,
      {Duration duration = _defaultMovementDuration, Curve curve = _defaultCurve}) async {
    assert(targetRatio >= -1 && targetRatio <= 1);
    if (_closing || _isInFullWidthAnimation) return;
    if (_animationController.value == 0.0) {
      ratio = (0.05 * targetRatio.sign);
    }
    return _animationController.animateTo(
      targetRatio.abs(),
      duration: duration,
      curve: curve,
    );
  }

  Future<void> dismiss(ResizeRequest request,
      {Duration duration = _defaultMovementDuration, Curve curve = _defaultCurve}) async {
    await _animationController.animateTo(1.0, duration: duration, curve: curve);
    resizeRequest.value = request;
  }

  void dispose() {
    _controllers.remove(this);
    _animationController.removeListener(_onAnimationChanged);
    _animationController.dispose();
    direction.removeListener(_onDirectionChanged);
    direction.dispose();
  }
}

class _ValueNotifier<T> extends ValueNotifier<T> {
  _ValueNotifier(T value) : super(value);
  bool get _hasListeners => hasListeners;
}
