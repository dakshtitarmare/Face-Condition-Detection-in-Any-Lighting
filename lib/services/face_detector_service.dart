import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// A detected face with its bounding box and the raw [Face] from ML Kit.
class DetectedFace {
  /// Axis-aligned bounding box in image-pixel coordinates.
  final Rect boundingBox;

  /// The full ML Kit [Face] object (landmarks, contours, probabilities, etc.).
  final Face face;

  const DetectedFace({required this.boundingBox, required this.face});

  @override
  String toString() =>
      'DetectedFace(trackingId=${face.trackingId}, boundingBox=$boundingBox)';
}

/// Wraps [FaceDetector] and converts a [CameraImage] into ML Kit's
/// [InputImage] before running detection.
///
/// Usage:
/// ```dart
/// final service = FaceDetectorService();
/// service.initialize();                        // call once
///
/// cameraService.frameStream.listen((frame) async {
///   final faces = await service.detectFaces(frame, controller.description);
///   for (final f in faces) print(f.boundingBox);
/// });
///
/// service.dispose();                           // call when done
/// ```
class FaceDetectorService {
  FaceDetector? _detector;

  // Guard against concurrent processImage calls (ML Kit is not re-entrant).
  bool _isBusy = false;
  bool _isDisposed = false;

  // ── Lifecycle ───────────────────────────────────────────────────────

  /// Whether [initialize] has been called and [dispose] has not yet been called.
  bool get isInitialized => _detector != null && !_isDisposed;

  /// Creates and configures the underlying [FaceDetector].
  ///
  /// Safe to call again to reconfigure — the previous detector is closed first.
  /// Throws [StateError] if called after [dispose].
  void initialize({
    bool enableTracking = true,
    bool enableClassification = true,
    bool enableLandmarks = false,
    bool enableContours = false,
    FaceDetectorMode performanceMode = FaceDetectorMode.fast,
    double minFaceSize = 0.1,
  }) {
    _assertNotDisposed();

    // Close any previous detector before replacing it.
    _detector?.close();

    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableTracking: enableTracking,
        enableClassification: enableClassification,
        enableLandmarks: enableLandmarks,
        enableContours: enableContours,
        performanceMode: performanceMode,
        minFaceSize: minFaceSize,
      ),
    );
    debugPrint('[FaceDetectorService] Initialized.');
  }

  /// Releases ML Kit resources.
  ///
  /// Calling [dispose] more than once is safe (subsequent calls are no-ops).
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await _detector?.close();
    _detector = null;
    debugPrint('[FaceDetectorService] Disposed.');
  }

  // ── Detection ───────────────────────────────────────────────────────

  /// Processes a single [CameraImage] frame and returns every detected face.
  ///
  /// [image]       – the raw frame from [CameraService.frameStream].
  /// [description] – the [CameraDescription] of the active camera, used to
  ///                 derive the correct [InputImageRotation].
  ///
  /// Returns an empty list when the detector is already busy with a previous
  /// frame, preventing queue build-up during fast streams.
  Future<List<DetectedFace>> detectFaces(
    CameraImage image,
    CameraDescription description,
  ) async {
    // ── Pre-flight guards ────────────────────────────────────────────
    if (!isInitialized) {
      debugPrint('[FaceDetectorService] detectFaces called before initialize() '
          'or after dispose() — skipping frame.');
      return [];
    }

    if (_isBusy) return [];

    // Validate image dimensions.
    if (image.width == 0 || image.height == 0) {
      debugPrint('[FaceDetectorService] Received zero-dimension image '
          '(${image.width}×${image.height}) — skipping frame.');
      return [];
    }

    // Validate plane count: Android YUV needs 3, iOS BGRA needs 1.
    final int expectedPlanes = Platform.isAndroid ? 3 : 1;
    if (image.planes.length < expectedPlanes) {
      debugPrint('[FaceDetectorService] Expected $expectedPlanes plane(s) but '
          'got ${image.planes.length} — skipping frame.');
      return [];
    }

    // Validate that no plane has empty bytes.
    for (int i = 0; i < expectedPlanes; i++) {
      if (image.planes[i].bytes.isEmpty) {
        debugPrint('[FaceDetectorService] Plane $i has 0 bytes — skipping frame.');
        return [];
      }
    }

    _isBusy = true;

    try {
      final inputImage = _toInputImage(image, description);
      if (inputImage == null) return [];

      final faces = await _detector!.processImage(inputImage);

      return faces
          .map((f) => DetectedFace(boundingBox: f.boundingBox, face: f))
          .toList();
    } catch (e, st) {
      debugPrint('[FaceDetectorService] Detection error: $e\n$st');
      return [];
    } finally {
      _isBusy = false;
    }
  }

  // ── InputImage conversion ───────────────────────────────────────────

  /// Converts a [CameraImage] (YUV-420 on Android, BGRA-8888 on iOS) into an
  /// [InputImage] that ML Kit can process.
  InputImage? _toInputImage(CameraImage image, CameraDescription description) {
    // ── Rotation ──────────────────────────────────────────────────────
    final rotation = _rotationFromSensorOrientation(
      description.sensorOrientation,
    );
    if (rotation == null) {
      debugPrint(
        '[FaceDetectorService] Unsupported sensor orientation: '
        '${description.sensorOrientation}',
      );
      return null;
    }

    // ── Format ────────────────────────────────────────────────────────
    final format = Platform.isAndroid
        ? InputImageFormat.nv21
        : InputImageFormat.bgra8888;

    // ── Bytes ─────────────────────────────────────────────────────────
    final bytes = _extractBytes(image);
    if (bytes == null || bytes.isEmpty) return null;

    // ── Metadata ──────────────────────────────────────────────────────
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,       // used on Android
      format: format,           // used on iOS
      bytesPerRow: image.planes[0].bytesPerRow, // used on iOS
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  /// Builds an NV21 buffer on Android by interleaving the V and U planes
  /// after the Y plane. Returns the single BGRA plane on iOS.
  ///
  /// The interleave loop is clamped so unequal-length V/U planes
  /// (which can occur on some Android OEM implementations) never cause
  /// an out-of-bounds write.
  Uint8List? _extractBytes(CameraImage image) {
    try {
      if (Platform.isAndroid) {
        final yPlane = image.planes[0];
        final uPlane = image.planes[1];
        final vPlane = image.planes[2];

        final int yLen = yPlane.bytes.length;
        final int vLen = vPlane.bytes.length;
        final int uLen = uPlane.bytes.length;

        // Each V byte is paired with one U byte, so the UV section is
        // 2 × min(vLen, uLen) bytes, matching the NV21 interleave exactly.
        final int uvLen = 2 * vLen.clamp(0, uLen);
        final nv21 = Uint8List(yLen + uvLen);

        nv21.setRange(0, yLen, yPlane.bytes);

        int offset = yLen;
        final int pairs = vLen.clamp(0, uLen); // safe upper bound
        for (int i = 0; i < pairs; i++) {
          nv21[offset++] = vPlane.bytes[i]; // V
          nv21[offset++] = uPlane.bytes[i]; // U
        }
        return nv21;
      } else {
        return image.planes[0].bytes;
      }
    } catch (e, st) {
      debugPrint('[FaceDetectorService] Byte extraction error: $e\n$st');
      return null;
    }
  }

  /// Maps the camera's sensor orientation (in degrees) to an
  /// [InputImageRotation] value.
  InputImageRotation? _rotationFromSensorOrientation(int sensorOrientation) {
    switch (sensorOrientation) {
      case 0:
        return InputImageRotation.rotation0deg;
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        debugPrint('[FaceDetectorService] Unknown sensor orientation: '
            '$sensorOrientation');
        return null;
    }
  }

  void _assertNotDisposed() {
    if (_isDisposed) {
      throw StateError(
        '[FaceDetectorService] This instance has been disposed '
        'and cannot be reused.',
      );
    }
  }
}
