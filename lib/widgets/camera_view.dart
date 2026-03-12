import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../services/camera_service.dart';
import '../services/face_detector_service.dart';
import 'face_overlay_painter.dart';

class CameraView extends StatefulWidget {
  const CameraView({super.key});

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> with WidgetsBindingObserver {
  final CameraService _cameraService = CameraService();
  final FaceDetectorService _detectorService = FaceDetectorService();

  StreamSubscription<CameraImage>? _frameSub;
  StreamSubscription<CameraException>? _cameraErrorSub;

  List<Face> _faces = [];
  Size _imageSize = Size.zero;
  _ViewState _viewState = _ViewState.initializing;
  String? _errorMessage;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _detectorService.initialize();
    _startCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_cameraService.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _frameSub?.cancel();
      _frameSub = null;
      _cameraService.stopStream();
    } else if (state == AppLifecycleState.resumed) {
      _startStream().catchError((Object e) {
        _setError('Failed to resume camera: $e');
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameSub?.cancel();
    _cameraErrorSub?.cancel();
    _cameraService.dispose();
    _detectorService.dispose();
    super.dispose();
  }

  // ── Camera setup ──────────────────────────────────────────────────────────

  Future<void> _startCamera() async {
    try {
      await _cameraService.initialize();

      _cameraErrorSub = _cameraService.cameraErrorStream.listen((
        CameraException e,
      ) {
        _setError('Hardware error – ${e.code}: ${e.description}');
      });

      await _startStream();
      if (mounted) setState(() => _viewState = _ViewState.running);
    } on CameraException catch (e) {
      _setError('${e.code}: ${e.description}');
    } catch (e) {
      _setError(e.toString());
    }
  }

  Future<void> _startStream() async {
    await _cameraService.startStream();

    _frameSub = _cameraService.frameStream.listen(
      _onFrame,
      onError: (Object e, StackTrace st) {
        debugPrint('[CameraView] Frame stream error: $e\n$st');
        _setError('Stream error: $e');
      },
      cancelOnError: false,
    );
  }

  // ── Frame processing ──────────────────────────────────────────────────────

  Future<void> _onFrame(CameraImage image) async {
    final controller = _cameraService.controller;
    if (controller == null || !controller.value.isInitialized) return;

    final detected = await _detectorService.detectFaces(
      image,
      controller.description,
    );

    if (!mounted) return;
    setState(() {
      _imageSize = Size(image.width.toDouble(), image.height.toDouble());
      _faces = detected.map((d) => d.face).toList();
    });
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setError(String message) {
    debugPrint('[CameraView] Error: $message');
    if (!mounted) return;
    setState(() {
      _viewState = _ViewState.error;
      _errorMessage = message;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: switch (_viewState) {
        _ViewState.initializing => const _CentredMessage(
          icon: Icons.camera_alt_outlined,
          text: 'Initialising camera…',
        ),
        _ViewState.error => _CentredMessage(
          icon: Icons.error_outline,
          text: _errorMessage ?? 'Unknown error',
          isError: true,
        ),
        _ViewState.running => _buildPreview(),
      },
    );
  }

  Widget _buildPreview() {
    final controller = _cameraService.controller;

    if (controller == null || !controller.value.isInitialized) {
      return const _CentredMessage(
        icon: Icons.camera_alt_outlined,
        text: 'Initialising camera…',
      );
    }

    final bool isFront =
        controller.description.lensDirection == CameraLensDirection.front;
    final int sensorOrientation = controller.description.sensorOrientation;

    return SafeArea(
      child: Column(
        children: [
          // ── padded preview card ──────────────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // The canvas must be exactly the visual preview rect.
                    // CameraPreview sizes itself via AspectRatio internally,
                    // so we let it determine its own size and overlay the
                    // CustomPaint on top of it with the same constraints.
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        // Black background behind the aspect-ratio preview.
                        Container(color: Colors.black),

                        // Live preview – AspectRatio-sized internally.
                        CameraPreview(controller),

                        // Overlay – must match what CameraPreview renders.
                        if (_imageSize != Size.zero)
                          Positioned.fill(
                            child: LayoutBuilder(
                              builder: (ctx, box) {
                                // Compute the actual preview rect inside
                                // the available space so the painter canvas
                                // matches pixel-for-pixel.
                                final double previewAspect =
                                    1 / controller.value.aspectRatio;
                                final double availW = box.maxWidth;
                                final double availH = box.maxHeight;

                                double pW, pH;
                                if (availW / availH > previewAspect) {
                                  // Height-constrained
                                  pH = availH;
                                  pW = availH * previewAspect;
                                } else {
                                  // Width-constrained
                                  pW = availW;
                                  pH = availW / previewAspect;
                                }

                                return Center(
                                  child: SizedBox(
                                    width: pW,
                                    height: pH,
                                    child: CustomPaint(
                                      painter: FaceOverlayPainter(
                                        faces: _faces,
                                        imageSize: _imageSize,
                                        previewSize: Size(pW, pH),
                                        sensorOrientation: sensorOrientation,
                                        isFrontCamera: isFront,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),

          // ── status banner ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _StatusBanner(
              faceDetected: _faces.isNotEmpty,
              faceCount: _faces.length,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helper widgets ─────────────────────────────────────────────────────────────

enum _ViewState { initializing, running, error }

/// Full-screen centred icon + message used for loading and error states.
class _CentredMessage extends StatelessWidget {
  const _CentredMessage({
    required this.icon,
    required this.text,
    this.isError = false,
  });

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? Colors.redAccent : Colors.white70;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 52),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 15),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// Frosted banner pinned to the bottom of the screen.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.faceDetected, required this.faceCount});

  final bool faceDetected;
  final int faceCount;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = faceDetected
        ? (
            faceCount == 1 ? 'Face detected' : '$faceCount faces detected',
            Icons.face,
            const Color(0xFF00E676),
          )
        : ('No face', Icons.face_retouching_off, Colors.white54);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.75), Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
