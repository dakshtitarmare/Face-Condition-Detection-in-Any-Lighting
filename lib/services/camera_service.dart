import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Manages the front-facing camera lifecycle.
///
/// Lifecycle order:
///   1. [initialize]  – find + configure the front camera
///   2. [startStream] – begin emitting [CameraImage] frames
///   3. [stopStream]  – pause the frame stream (camera stays alive)
///   4. [dispose]     – release every resource; the service cannot be reused
///
/// Listen to [cameraErrorStream] to react to hardware errors that surface
/// after initialization (e.g. another app stealing the camera).
class CameraService {
  CameraController? _controller;

  // Frames broadcast to listeners.
  final StreamController<CameraImage> _frameStreamController =
      StreamController<CameraImage>.broadcast();

  // Post-init hardware errors forwarded from CameraController.addListener.
  final StreamController<CameraException> _errorStreamController =
      StreamController<CameraException>.broadcast();

  bool _isStreaming = false;
  bool _isDisposed = false;

  // ── Public getters ──────────────────────────────────────────────────

  /// The underlying [CameraController]. Null until [initialize] completes.
  CameraController? get controller => _controller;

  /// Whether the controller has been created and is initialized.
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  /// Whether the camera is currently streaming frames.
  bool get isStreaming => _isStreaming;

  /// Broadcast stream of raw [CameraImage] frames from the front camera.
  Stream<CameraImage> get frameStream => _frameStreamController.stream;

  /// Broadcast stream of [CameraException]s that occur after initialization
  /// (e.g. the camera being claimed by another process).
  Stream<CameraException> get cameraErrorStream =>
      _errorStreamController.stream;

  // ── Lifecycle ───────────────────────────────────────────────────────

  /// Finds the front camera, creates and initializes a [CameraController].
  ///
  /// Safe to call again after a recoverable error: the previous controller
  /// is disposed before a new one is created.
  ///
  /// Throws [CameraException] if no front camera is found or initialization
  /// fails. Throws [StateError] if [dispose] has already been called.
  Future<void> initialize({
    ResolutionPreset resolution = ResolutionPreset.high,
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.yuv420,
  }) async {
    _assertNotDisposed();

    // Tear down any existing controller before replacing it.
    await _releaseController();

    final cameras = await availableCameras();

    // Guard: no cameras available at all.
    if (cameras.isEmpty) {
      throw CameraException(
        'NoCameraFound',
        'No cameras are available on this device.',
      );
    }

    final CameraDescription? front = cameras
        .cast<CameraDescription?>()
        .firstWhere(
          (c) => c!.lensDirection == CameraLensDirection.front,
          orElse: () => null,
        );

    if (front == null) {
      throw CameraException(
        'NoCameraFound',
        'No front-facing camera is available on this device.',
      );
    }

    final controller = CameraController(
      front,
      resolution,
      enableAudio: false,
      imageFormatGroup: imageFormatGroup,
    );

    await controller.initialize();

    // Wire up a listener that forwards post-init hardware errors.
    controller.addListener(() {
      if (controller.value.hasError) {
        final error = CameraException(
          'CameraError',
          controller.value.errorDescription ?? 'Unknown camera error',
        );
        debugPrint('[CameraService] Hardware error: ${error.description}');
        if (!_errorStreamController.isClosed) {
          _errorStreamController.add(error);
        }
      }
    });

    _controller = controller;
    debugPrint(
      '[CameraService] Front camera initialized '
      '(${front.name}, ${resolution.name}).',
    );
  }

  /// Starts streaming frames into [frameStream].
  ///
  /// [initialize] must be called first.
  /// Calling this while already streaming is a no-op.
  Future<void> startStream() async {
    _assertNotDisposed();
    _assertInitialized();
    if (_isStreaming) return;

    try {
      await _controller!.startImageStream((CameraImage image) {
        if (!_frameStreamController.isClosed) {
          _frameStreamController.add(image);
        }
      });
      _isStreaming = true;
      debugPrint('[CameraService] Frame stream started.');
    } catch (e) {
      // _isStreaming stays false; surface the error to the caller.
      debugPrint('[CameraService] startImageStream failed: $e');
      rethrow;
    }
  }

  /// Stops streaming frames. The camera stays alive; call [startStream] to
  /// resume. Calling this when not streaming is a no-op.
  Future<void> stopStream() async {
    if (!_isStreaming) return;

    try {
      await _controller?.stopImageStream();
      debugPrint('[CameraService] Frame stream stopped.');
    } catch (e) {
      debugPrint('[CameraService] stopImageStream error (ignored): $e');
    } finally {
      // Always reset the flag, even if stopImageStream threw.
      _isStreaming = false;
    }
  }

  /// Stops any active stream, disposes the [CameraController], and closes
  /// both internal [StreamController]s.
  ///
  /// Calling [dispose] more than once is safe (subsequent calls are no-ops).
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    await stopStream();
    await _releaseController();
    await _frameStreamController.close();
    await _errorStreamController.close();

    debugPrint('[CameraService] Disposed.');
  }

  // ── Internals ───────────────────────────────────────────────────────

  /// Disposes and nullifies the current controller, if any.
  Future<void> _releaseController() async {
    final old = _controller;
    _controller = null;
    if (old != null) {
      try {
        await old.dispose();
      } catch (e) {
        debugPrint('[CameraService] Controller dispose error (ignored): $e');
      }
    }
  }

  void _assertInitialized() {
    if (!isInitialized) {
      throw StateError(
        '[CameraService] Not initialized – call initialize() first.',
      );
    }
  }

  void _assertNotDisposed() {
    if (_isDisposed) {
      throw StateError(
        '[CameraService] This instance has been disposed and cannot be reused.',
      );
    }
  }
}
