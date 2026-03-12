import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Paints a bounding-box rectangle over every detected [Face].
///
/// Coordinate-space alignment
/// ──────────────────────────
/// ML Kit receives the raw CameraImage bytes in the sensor's native
/// orientation (landscape on most Android phones, sensorOrientation = 90°
/// or 270°).  The bounding-box coordinates it returns are therefore in that
/// **landscape** space.
///
/// CameraPreview internally applies a RotatedBox so the live feed appears
/// in portrait on screen.  To paint boxes in the same coordinate space the
/// preview occupies we must:
///   1. Swap imageSize width↔height when sensorOrientation is 90° or 270°
///      so our "logical image size" is portrait, matching the display.
///   2. Mirror X for the front camera (CameraPreview mirrors the feed).
///
/// [sensorOrientation] must be the value from
/// [CameraDescription.sensorOrientation] (0 / 90 / 180 / 270).
class FaceOverlayPainter extends CustomPainter {
  const FaceOverlayPainter({
    required this.faces,
    required this.imageSize,
    required this.previewSize,
    required this.sensorOrientation,
    this.isFrontCamera = true,
  });

  final List<Face> faces;

  /// Raw pixel dimensions of the CameraImage (before any rotation).
  final Size imageSize;

  /// Rendered size of the CameraPreview widget on screen.
  final Size previewSize;

  /// Degrees from CameraDescription.sensorOrientation (0/90/180/270).
  final int sensorOrientation;

  final bool isFrontCamera;

  // ── Paint styles ──────────────────────────────────────────────────────────

  static final Paint _boxPaint = Paint()
    ..color = const Color(0xFF00E676)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5;

  static const TextStyle _labelStyle = TextStyle(
    color: Color(0xFF00E676),
    fontSize: 13,
    fontWeight: FontWeight.w600,
    shadows: [Shadow(blurRadius: 4, color: Colors.black)],
  );

  // ── CustomPainter ─────────────────────────────────────────────────────────

  @override
  void paint(Canvas canvas, Size size) {
    if (faces.isEmpty) return;

    // Step 1 – derive the *display-space* image dimensions.
    //
    // When sensorOrientation is 90° or 270° the sensor delivers landscape
    // frames, but CameraPreview rotates them to portrait.  We swap the raw
    // dimensions so our scale factors work in portrait space.
    final bool isRotated =
        sensorOrientation == 90 || sensorOrientation == 270;

    final double imageW = isRotated ? imageSize.height : imageSize.width;
    final double imageH = isRotated ? imageSize.width  : imageSize.height;

    // Step 2 – scale factors from display-image-space → canvas-space.
    final double scaleX = size.width  / imageW;
    final double scaleY = size.height / imageH;

    for (final Face face in faces) {
      final Rect raw = face.boundingBox;

      double left   = raw.left   * scaleX;
      double top    = raw.top    * scaleY;
      double right  = raw.right  * scaleX;
      double bottom = raw.bottom * scaleY;

      // Step 3 – mirror X for the front camera.
      if (isFrontCamera) {
        final double ml = size.width - right;
        final double mr = size.width - left;
        left  = ml;
        right = mr;
      }

      final Rect scaledRect = Rect.fromLTRB(left, top, right, bottom);
      canvas.drawRect(scaledRect, _boxPaint);
      _drawLabel(canvas, scaledRect, face);
    }
  }

  void _drawLabel(Canvas canvas, Rect rect, Face face) {
    final String label =
        face.trackingId != null ? 'Face #${face.trackingId}' : 'Face';

    final TextPainter tp = TextPainter(
      text: TextSpan(text: label, style: _labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    final double dx = rect.left.clamp(0.0, previewSize.width  - tp.width);
    final double dy = (rect.top - tp.height - 4).clamp(0.0, double.infinity);
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(FaceOverlayPainter old) =>
      old.faces             != faces             ||
      old.imageSize         != imageSize         ||
      old.previewSize       != previewSize       ||
      old.sensorOrientation != sensorOrientation;
}
