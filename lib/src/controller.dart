import 'package:flutter/widgets.dart';

const _defaultMovementDuration = Duration(milliseconds: 200);
const _defaultCurve = Curves.ease;

/// The different kinds of action panes.
enum ActionPaneType {
  /// The end action pane is shown.
  end,

  /// No action pane is shown.
  none,

  /// The start action pane is shown.
  start,
}

/// Represents how the ratio should changes.
abstract class RatioConfigurator {
  /// Makes sure the given [ratio] is between the bounds.
  double normalizeRatio(double ratio);

  /// The total extent ratio of this configurator.
  double get extentRatio;

  /// A method to call when the end gesture changed.
  void handleEndGestureChanged();
}

/// The direction of a gesture in the context of [Slidable].
enum GestureDirection {
  /// The direction in which the user want to show the action pane.
  opening,

  /// The direction in which the user want to hide the action pane.
  closing,
}

/// A request made to resize a [Slidable] after a dismiss.
@immutable
class ResizeRequest {
  /// Creates a [ResizeRequest].
  const ResizeRequest(this.duration, this.onDismissed);

  /// The duration of the resize.
  final Duration duration;

  /// The callback to execute when the resize finishes.
  final VoidCallback onDismissed;
}

/// Represents an intention to dismiss a [Slidable].
@immutable
class DismissGesture {
  /// Creates a [DismissGesture].
  const DismissGesture(this.endGesture);

  /// The [EndGesture] provoking this one.
  final EndGesture? endGesture;
}

/// Represents the end of a gesture on [Slidable].
@immutable
class EndGesture {
  /// Creates an [EndGesture].
  const EndGesture(this.velocity);

  /// The velocity of the gesture.
  final double velocity;
}

/// Represents a gesture used explicitly to open a [Slidable].
class OpeningGesture extends EndGesture {
  /// Creates an [OpeningGesture].
  const OpeningGesture(double velocity) : super(velocity);
}

/// Represents a gesture used explicitly to close a [Slidable].
class ClosingGesture extends EndGesture {
  /// Creates a [ClosingGesture].
  const ClosingGesture(double velocity) : super(velocity);
}

/// Represents an end gesture without velocity.
class StillGesture extends EndGesture {
  /// Creates a [StillGesture].
  const StillGesture(this.direction) : super(0);

  /// The direction in which the user dragged the [Slidable].
  final GestureDirection direction;

  /// Whether the user was in the process to open the [Slidable].
  bool get opening => direction == GestureDirection.opening;

  /// Whether the user was in the process to close the [Slidable].
  bool get closing => direction == GestureDirection.closing;
}

/// Represents a way to control a slidable from outside.
class SlidableController {
  static final List<SlidableController> _controllers = [];
  
  SlidableController(
    TickerProvider vsync, {
    this.onFullyExtended,
    this.fullWidthDuration = const Duration(milliseconds: 300),
    this.fullWidthDelay = const Duration(milliseconds: 500),
    this.snapBackThresholdRatio = 0.5, // [Snap-back logic] Default 1/2 extentRatio
    this.allowFullWidthBeyondExtentRatio = false, // [Full-width logic] Default false
  }) : assert(snapBackThresholdRatio >= 0 && snapBackThresholdRatio <= 1,
            'snapBackThresholdRatio must be between 0 and 1'),
        _animationController = AnimationController(vsync: vsync),
        endGesture = ValueNotifier<EndGesture?>(null),
        _dismissGesture = _ValueNotifier<DismissGesture?>(null),
        resizeRequest = ValueNotifier<ResizeRequest?>(null),
        actionPaneType = ValueNotifier<ActionPaneType>(ActionPaneType.none),
        direction = ValueNotifier<int>(0) {
    direction.addListener(_onDirectionChanged);

    // Tambahkan ke daftar controller global
    _controllers.add(this);

    // Listen perubahan animasi untuk auto-close yang lain
    _animationController.addListener(_onAnimationChanged);
  }

  /// Callback yang dipanggil ketika slidable mencapai posisi fully extended
  final VoidCallback? onFullyExtended;
  
  /// Durasi animasi untuk extend ke full width
  final Duration fullWidthDuration;
  
  /// Delay sebelum auto close setelah full width
  final Duration fullWidthDelay;
  
  /// Persentase batas kapan Slidable akan snap-back (0.0 - 1.0)
  final double snapBackThresholdRatio; // [Snap-back logic]

  /// Whether the action pane is allowed to slide beyond extentRatio to full width
  final bool allowFullWidthBeyondExtentRatio; // [Full-width logic]

  bool _hasCalledFullyExtended = false;
  bool _isInFullWidthAnimation = false;
  bool _isClosingOthers = false;

  final AnimationController _animationController;
  final _ValueNotifier<DismissGesture?> _dismissGesture;

  /// Whether the start action pane is enabled.
  bool enableStartActionPane = true;

  /// Whether the end action pane is enabled.
  bool enableEndActionPane = true;

  /// Whether the start action pane is at the left (if horizontal).
  /// Defaults to true.
  bool isLeftToRight = true;

  double _startActionPaneExtentRatio = 0.0;
  double _endActionPaneExtentRatio = 0.0;

  /// The current action pane configurator.
  RatioConfigurator? get actionPaneConfigurator => _actionPaneConfigurator;
  RatioConfigurator? _actionPaneConfigurator;
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

  /// The value of the ratio over time.
  Animation<double> get animation => _animationController.view;

  /// Track the end gestures.
  final ValueNotifier<EndGesture?> endGesture;

  /// Track the dismiss gestures.
  ValueNotifier<DismissGesture?> get dismissGesture => _dismissGesture;

  /// Track the resize requests.
  final ValueNotifier<ResizeRequest?> resizeRequest;

  /// Track the type of the action pane.
  final ValueNotifier<ActionPaneType> actionPaneType;

  /// Track the direction in which the slidable moves.
  ///
  /// -1 means that the slidable is moving to the left.
  ///  0 means that the slidable is not moving.
  ///  1 means that the slidable is moving to the right.
  final ValueNotifier<int> direction;

  /// Indicates whether the dismissible registered to gestures.
  bool get isDismissibleReady => _dismissGesture._hasListeners;

  /// Whether this [close()] method has been called and not finished.
  bool get closing => _closing;
  bool _closing = false;

  bool _acceptRatio(double ratio) {
    return !_closing &&
        (ratio == 0 ||
            ((ratio > 0 && enablePositiveActionPane) ||
                (ratio < 0 && enableNegativeActionPane)));
  }

  /// Whether the positive action pane is enabled.
  bool get enablePositiveActionPane =>
      isLeftToRight ? enableStartActionPane : enableEndActionPane;

  /// Whether the negative action pane is enabled.
  bool get enableNegativeActionPane =>
      isLeftToRight ? enableEndActionPane : enableStartActionPane;

  /// The extent ratio of the start action pane.
  double get startActionPaneExtentRatio => _startActionPaneExtentRatio;
  set startActionPaneExtentRatio(double value) {
    if (_startActionPaneExtentRatio != value && value >= 0 && value <= 1) {
      _startActionPaneExtentRatio = value;
    }
  }

  /// The extent ratio of the end action pane.
  double get endActionPaneExtentRatio => _endActionPaneExtentRatio;
  set endActionPaneExtentRatio(double value) {
    if (_endActionPaneExtentRatio != value && value >= 0 && value <= 1) {
      _endActionPaneExtentRatio = value;
    }
  }

  /// The current ratio of the full size of the [Slidable] that is already
  /// dragged.
  ///
  /// This is between -1 and 1.
  /// Between -1 (inclusive) and 0(exclusive), the action pane is
  /// [ActionPaneType.end].
  /// Between 0 (exclusive) and 1 (inclusive), the action pane is
  /// [ActionPaneType.start].
  double get ratio => _animationController.value * direction.value;
  set ratio(double value) {
    final double newRatio = (actionPaneConfigurator?.normalizeRatio(value)) ?? value;

    // [Full-width logic] compute extent once
    final double extent = actionPaneConfigurator?.extentRatio ?? 0.0;

    // clamp returns num, convert to double
    final num clampedNum = allowFullWidthBeyondExtentRatio
        ? newRatio.clamp(-1.0, 1.0)
        : newRatio.clamp(-extent, extent);

    final double allowedRatio = clampedNum.toDouble();

    if (_acceptRatio(allowedRatio) && allowedRatio != ratio) {
      direction.value = allowedRatio.sign.toInt();
      _animationController.value = allowedRatio.abs().toDouble();
    }
  }

  void _onAnimationChanged() {
    // Jangan lakukan auto-close jika sedang dalam proses menutup controller lain
    // atau sedang dalam proses full width animation
    if (_isClosingOthers || _isInFullWidthAnimation) return;
    
    // Check untuk fully extended callback
    final currentlyFullyExtended = isFullyExtended;
    
    // Panggil callback hanya sekali ketika mencapai fully extended
    if (currentlyFullyExtended && !_hasCalledFullyExtended && onFullyExtended != null) {
      _hasCalledFullyExtended = true;
      // Jalankan animasi full width dengan auto close
      _animateToFullWidthThenClose();
    }
    
    // Reset flag ketika tidak fully extended
    if (!currentlyFullyExtended) {
      _hasCalledFullyExtended = false;
    }
    
    // Hanya lakukan auto-close ketika controller ini benar-benar sudah terbuka
    // dan tidak sedang dalam proses menutup atau full width animation
    if (currentlyFullyExtended && !_closing && !_isInFullWidthAnimation) {
      _closeOtherControllers();
    }
  }

  /// Animasi ke full width kemudian auto close
  Future<void> _animateToFullWidthThenClose() async {
    if (_isInFullWidthAnimation || _closing) return;
    
    _isInFullWidthAnimation = true;
    
    try {
      // Panggil callback terlebih dahulu
      onFullyExtended?.call();
      
      // Animasi ke full width (ratio 1.0)
      await _animationController.animateTo(
        1.0,
        duration: fullWidthDuration,
        curve: Curves.easeOut,
      );
      
      // Tunggu delay sebelum close
      await Future.delayed(fullWidthDelay);
      
      // Auto close
      await close(
        duration: fullWidthDuration,
        curve: Curves.easeIn,
      );
      
    } finally {
      _isInFullWidthAnimation = false;
    }
  }

  void _closeOtherControllers() {
    _isClosingOthers = true;
    
    for (final controller in _controllers) {
      if (controller != this && controller.isExtended && !controller._closing) {
        // Tutup tanpa animasi untuk menghindari konflik
        controller._closeImmediately();
      }
    }
    
    _isClosingOthers = false;
  }

  // Method untuk menutup langsung tanpa animasi
  void _closeImmediately() {
    _animationController.value = 0.0;
    direction.value = 0;
    _hasCalledFullyExtended = false; // Reset callback flag
    _isInFullWidthAnimation = false; // Reset full width flag
  }

  /// Apakah Slidable sedang terbuka (sebagian atau penuh).
  bool get isExtended => _animationController.value > 0.0;

  /// Apakah Slidable tertutup penuh.
  bool get isClosed => _animationController.value == 0.0;

  /// Apakah Slidable terbuka penuh sesuai konfigurasi extent.
  bool get isFullyExtended {
    final extentRatio = actionPaneConfigurator?.extentRatio ?? 0.0;
    return extentRatio > 0.0 && 
           (_animationController.value >= extentRatio - 0.01); // Toleransi kecil untuk floating point
  }

  void _onDirectionChanged() {
    final mulitiplier = isLeftToRight ? 1 : -1;
    final index = (direction.value * mulitiplier) + 1;
    actionPaneType.value = ActionPaneType.values[index];
  }

  /// Dispatches a new [EndGesture] determined by the given [velocity] and
  /// [direction].
  ///
  /// Ditambah logika:
  /// - Jika extent belum mencapai setengah extentRatio → close
  /// - Jika lebih dari setengah extentRatio → buka penuh
  void dispatchEndGesture(double? velocity, GestureDirection direction) {
    if (velocity == 0 || velocity == null) {
      endGesture.value = StillGesture(direction);
    } else if (velocity.sign == this.direction.value) {
      endGesture.value = OpeningGesture(velocity);
    } else {
      endGesture.value = ClosingGesture(velocity.abs());
    }

    // [Snap-back logic: gunakan snapBackThresholdRatio]
    final double extent = actionPaneConfigurator?.extentRatio ?? 0.0;
    if (extent > 0.0) {
      final double progress = _animationController.value;
      if (progress < extent * snapBackThresholdRatio) {
        // Kurang dari threshold → close
        close(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      } else {
        // Lebih dari threshold → buka penuh
        openCurrentActionPane(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      }
    }

    if (actionPaneConfigurator == null) {
      _replayEndGesture = true;
    }
  }

  /// Closes the [Slidable].
  Future<void> close({
    Duration duration = _defaultMovementDuration,
    Curve curve = _defaultCurve,
  }) async {
    _closing = true;
    _isInFullWidthAnimation = false; // Stop full width animation jika sedang berjalan
    await _animationController.animateBack(
      0.0,
      duration: duration,
      curve: curve,
    );
    direction.value = 0;
    _hasCalledFullyExtended = false; // Reset callback flag saat close
    _closing = false;
  }

  /// Opens the current [ActionPane].
  Future<void> openCurrentActionPane({
    Duration duration = _defaultMovementDuration,
    Curve curve = _defaultCurve,
  }) async {
    return openTo(
      actionPaneConfigurator!.extentRatio,
      duration: duration,
      curve: curve,
    );
  }

  /// Opens the [Slidable.startActionPane].
  Future<void> openStartActionPane({
    Duration duration = _defaultMovementDuration,
    Curve curve = _defaultCurve,
  }) async {
    if (actionPaneType.value != ActionPaneType.start) {
      direction.value = isLeftToRight ? 1 : -1;
      ratio = 0.0;
    }

    return openTo(
      startActionPaneExtentRatio,
      duration: duration,
      curve: curve,
    );
  }

  /// Opens the [Slidable.endActionPane].
  Future<void> openEndActionPane({
    Duration duration = _defaultMovementDuration,
    Curve curve = _defaultCurve,
  }) async {
    if (actionPaneType.value != ActionPaneType.end) {
      direction.value = isLeftToRight ? -1 : 1;
      ratio = 0.0;
    }

    return openTo(
      -endActionPaneExtentRatio,
      duration: duration,
      curve: curve,
    );
  }

  /// Opens the [Slidable] to the given [ratio].
  Future<void> openTo(
    double ratio, {
    Duration duration = _defaultMovementDuration,
    Curve curve = _defaultCurve,
  }) async {
    assert(ratio >= -1 && ratio <= 1);

    if (_closing || _isInFullWidthAnimation) {
      return;
    }

    // Edge case: to be able to correctly set the sign when the value is zero,
    // we have to manually set the ratio to a tiny amount.
    if (_animationController.value == 0.0) {
      this.ratio = (0.05 * ratio.sign).toDouble();
    }
    return _animationController.animateTo(
      ratio.abs().toDouble(),
      duration: duration,
      curve: curve,
    );
  }

  /// Dismisses the [Slidable].
  Future<void> dismiss(
    ResizeRequest request, {
    Duration duration = _defaultMovementDuration,
    Curve curve = _defaultCurve,
  }) async {
    await _animationController.animateTo(
      1.0,
      duration: _defaultMovementDuration,
      curve: curve,
    );
    resizeRequest.value = request;
  }

  /// Disposes the controller.
  void dispose() {
    _controllers.remove(this); // hapus dari daftar global
    _animationController.removeListener(_onAnimationChanged);
    _animationController.stop();
    _animationController.dispose();
    direction.removeListener(_onDirectionChanged);
    direction.dispose();
  }
}

class _ValueNotifier<T> extends ValueNotifier<T> {
  _ValueNotifier(T value) : super(value);

  bool get _hasListeners => hasListeners;
}
