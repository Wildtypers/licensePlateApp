import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

class MySecondPage extends StatefulWidget {
  const MySecondPage({super.key});

  @override
  State<MySecondPage> createState() => _MySecondPageState();
}

class _MySecondPageState extends State<MySecondPage>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _isDetecting = false;
  String _recognizedText = 'Scanning...';
  Uint8List? _lastCroppedPlate;

  final _textRecognizer = TextRecognizer();

  int _frameCounter = 0;
  final int _frameSkip = 30; // Process 1 frame every 30 frames

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    _cameraController =
        CameraController(cameras[0], ResolutionPreset.high, enableAudio: false);
    await _cameraController!.initialize();
    if (!mounted) return;

    _cameraController!.startImageStream((CameraImage image) {
      _frameCounter++;
      if (_isDetecting || _frameCounter % _frameSkip != 0) return;

      _isDetecting = true;
      _processCameraImage(image);
    });

    setState(() {});
  }

  Future<void> _processCameraImage(CameraImage image) async {
    try {
      final inputImage = _convertCameraImage(image);
      if (inputImage == null) return;

      final recognizedText = await _textRecognizer.processImage(inputImage);

      if (recognizedText.text.isNotEmpty && recognizedText.blocks.isNotEmpty) {
        final block = recognizedText.blocks.first;

        final plateBytes = _cropCameraImage(image, block.boundingBox);
        if (mounted) {
          setState(() {
            _lastCroppedPlate = plateBytes;
            _recognizedText =
                block.text.replaceAll(RegExp(r'\s'), '').toUpperCase();
          });
        }
      } else {
        if (mounted) setState(() => _recognizedText = 'Scanning...');
      }
    } catch (e) {
      print("❌ ML Kit error: $e");
    } finally {
      if (mounted) {
        _isDetecting = false;
      }
    }
  }

  // FIX 1: Updated the image conversion method
  InputImage? _convertCameraImage(CameraImage image) {
    // The `fromRaw` method is no longer available.
    // We need to manually construct the InputImage from the camera image planes.
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());

    // For a back camera in portrait mode, the orientation is 90 degrees.
    // This might need adjustment if you support landscape mode.
    final imageRotation = InputImageRotation.rotation90deg;

    // Use the NV21 format, which is common for Android.
    // The original code also made this assumption.
    final imageFormat = InputImageFormat.nv21;

    final metadata = InputImageMetadata(
      size: imageSize,
      rotation: imageRotation,
      format: imageFormat,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  Uint8List _cropCameraImage(CameraImage image, Rect boundingBox) {
    // The YUV to RGB conversion logic remains the same.
    final imgImage = img.Image(width: image.width, height: image.height);
    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;
    final uvRowStride = image.planes[1].bytesPerRow;
    final uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    for (int y = 0; y < image.height; y++) {
      final uvRow = y ~/ 2;
      for (int x = 0; x < image.width; x++) {
        final uvCol = x ~/ 2;
        final uvIndex = uvRow * uvRowStride + uvCol * uvPixelStride;
        final yp = yPlane[y * image.width + x].toDouble();
        final up = uPlane[uvIndex].toDouble() - 128.0;
        final vp = vPlane[uvIndex].toDouble() - 128.0;

        int r = (yp + 1.402 * vp).round().clamp(0, 255);
        int g = (yp - 0.344136 * up - 0.714136 * vp).round().clamp(0, 255);
        int b = (yp + 1.772 * up).round().clamp(0, 255);

        // FIX 2: Added the alpha value (255 for opaque) to setPixelRgba
        imgImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    final cropX = boundingBox.left.toInt().clamp(0, imgImage.width);
    final cropY = boundingBox.top.toInt().clamp(0, imgImage.height);
    final cropW = boundingBox.width.toInt().clamp(0, imgImage.width - cropX);
    final cropH =
        boundingBox.height.toInt().clamp(0, imgImage.height - cropY);

    final cropped =
        img.copyCrop(imgImage, x: cropX, y: cropY, width: cropW, height: cropH);

    return Uint8List.fromList(img.encodePng(cropped));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final screenSize = MediaQuery.of(context).size;
    final previewSize = _cameraController!.value.previewSize!;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text("License Plate Detection")),
      body: Center(
        child: SizedBox(
          width: screenSize.width,
          height: screenSize.width,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: previewSize.height,
                    height: previewSize.width,
                    child: CameraPreview(_cameraController!),
                  ),
                ),
                if (_lastCroppedPlate != null)
                  Positioned(
                    top: 16,
                    right: 16,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Image.memory(
                        _lastCroppedPlate!,
                        width: 200,
                        height: 60,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _recognizedText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}