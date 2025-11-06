import 'dart:isolate';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:math';

// ===============================
//  Data classes
// ===============================
class IsolateInitData {
  final SendPort mainSendPort;
  final Uint8List modelData;
  IsolateInitData(this.mainSendPort, this.modelData);
}

class IsolateInferenceData {
  final List<Uint8List> planes;
  final int height;
  final int width;
  final int uvRowStride;
  final int uvPixelStride;
  IsolateInferenceData(
      this.planes, this.height, this.width, this.uvRowStride, this.uvPixelStride);
}

// ===================================================
// --- Non-Maximum Suppression Helpers
// ===================================================
double iou(Map<String, dynamic> box1, Map<String, dynamic> box2) {
  final rect1 = box1['rect'] as Map<String, dynamic>;
  final rect2 = box2['rect'] as Map<String, dynamic>;
  final double x1 = max(rect1['left'], rect2['left']);
  final double y1 = max(rect1['top'], rect2['top']);
  final double x2 = min(rect1['left'] + rect1['width'], rect2['left'] + rect2['width']);
  final double y2 = min(rect1['top'] + rect1['height'], rect2['top'] + rect2['height']);
  final intersectionArea = max(0, x2 - x1) * max(0, y2 - y1);
  final box1Area = rect1['width'] * rect1['height'];
  final box2Area = rect2['width'] * rect2['height'];
  final unionArea = box1Area + box2Area - intersectionArea;
  return unionArea > 0 ? intersectionArea / unionArea : 0;
}

List<Map<String, dynamic>> nonMaxSuppression(List<Map<String, dynamic>> boxes, double iouThreshold) {
  if (boxes.isEmpty) return [];
  boxes.sort((a, b) => (b['confidence'] as double).compareTo(a['confidence'] as double));
  final List<Map<String, dynamic>> selected = [];
  final List<bool> suppressed = List.filled(boxes.length, false);
  for (int i = 0; i < boxes.length; i++) {
    if (suppressed[i]) continue;
    selected.add(boxes[i]);
    for (int j = i + 1; j < boxes.length; j++) {
      if (suppressed[j]) continue;
      if (iou(boxes[i], boxes[j]) > iouThreshold) {
        suppressed[j] = true;
      }
    }
  }
  return selected;
}

// ===================================================
// --- Isolate function for YOLO inference
// ===================================================
void imageProcessor(IsolateInitData initData) async {
  final mainSendPort = initData.mainSendPort;
  final isolateReceivePort = ReceivePort();
  mainSendPort.send(isolateReceivePort.sendPort);

  Interpreter? interpreter;
  try {
    interpreter = Interpreter.fromBuffer(initData.modelData);
  } catch (e) {
    print("❌ Isolate: Failed to load model: $e");
    return;
  }

  const int inputWidth = 640;
  const int inputHeight = 640;
  const int numDetections = 8400;
  final outputShape = [1, 5, numDetections];

  await for (final IsolateInferenceData isolateData in isolateReceivePort) {
    try {
      final rgbImage = convertFromRawData(isolateData);
      if (rgbImage == null) {
        mainSendPort.send(null);
        continue;
      }

      final rotated = img.copyRotate(rgbImage, angle: 90);
      final resized = img.copyResize(rotated, width: inputWidth, height: inputHeight);

      final input = Float32List(inputWidth * inputHeight * 3);
      int idx = 0;
      for (final pixel in resized) {
        input[idx++] = pixel.r / 255.0;
        input[idx++] = pixel.g / 255.0;
        input[idx++] = pixel.b / 255.0;
      }

      final shapedInput = input.reshape([1, inputHeight, inputWidth, 3]);
      final output = List.filled(outputShape.reduce((a, b) => a * b), 0.0).reshape(outputShape);

      interpreter.run(shapedInput, output);

      List<Map<String, dynamic>> recognitions = [];
      // This threshold might need tuning (e.g., 0.25) depending on the model and conditions.
      for (int i = 0; i < numDetections; i++) {
        final conf = output[0][4][i];
        if (conf > 0.25) { 
          final cx = output[0][0][i];
          final cy = output[0][1][i];
          final w = output[0][2][i];
          final h = output[0][3][i];
          recognitions.add({
            "rect": {
              "left": (cx - w / 2) * inputWidth,
              "top": (cy - h / 2) * inputHeight,
              "width": w * inputWidth,
              "height": h * inputHeight
            },
            "confidence": conf,
          });
        }
      }

      final List<Map<String, dynamic>> finalDetections = nonMaxSuppression(recognitions, 0.4);
      mainSendPort.send({'detections': finalDetections, 'image': rotated});

    } catch (e) {
      print("❌ Isolate: Error during processing: $e");
      mainSendPort.send(null);
    }
  }
}

// ===================================================
// --- Convert YUV420 → RGB
// ===================================================
img.Image? convertFromRawData(IsolateInferenceData data) {
  try {
    final width = data.width;
    final height = data.height;
    final imgImage = img.Image(width: width, height: height);
    final yPlane = data.planes[0];
    final uPlane = data.planes[1];
    final vPlane = data.planes[2];

    for (int y = 0; y < height; y++) {
      final uvRow = (y / 2).floor();
      for (int x = 0; x < width; x++) {
        final uvCol = (x / 2).floor();
        final uvIndex = uvRow * data.uvRowStride + uvCol * data.uvPixelStride;
        final index = y * width + x;

        if (uvIndex >= uPlane.length ||
            uvIndex >= vPlane.length ||
            index >= yPlane.length) continue;

        final yp = yPlane[index].toDouble();
        final up = uPlane[uvIndex].toDouble() - 128.0;
        final vp = vPlane[uvIndex].toDouble() - 128.0;

        int r = (yp + 1.402 * vp).round().clamp(0, 255);
        int g = (yp - 0.344136 * up - 0.714136 * vp).round().clamp(0, 255);
        int b = (yp + 1.772 * up).round().clamp(0, 255);

        imgImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    return imgImage;
  } catch (e) {
    print("⚠️ YUV→RGB conversion failed: $e");
    return null;
  }
}

// ===================================================
// --- Main Page
// ===================================================
class MySecondPage extends StatefulWidget {
  const MySecondPage({super.key});
  @override
  State<MySecondPage> createState() => _MySecondPageState();
}

class _MySecondPageState extends State<MySecondPage> with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<dynamic>? _recognitions;
  bool _isDetecting = false;

  Isolate? _isolate;
  final ReceivePort _mainReceivePort = ReceivePort();
  SendPort? _isolateSendPort;
  final Completer<void> _isolateReadyCompleter = Completer<void>();

  final TextRecognizer _textRecognizer = TextRecognizer();
  String _recognizedPlateText = 'Scanning...';

  int _frameCounter = 0;
  final int _frameSkip = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    await _initializeIsolate();
    await _isolateReadyCompleter.future;
    await _initializeCamera();
  }

  Future<void> _initializeIsolate() async {
    final modelData = await rootBundle.load('assets/yolov8n_float32.tflite');
    final modelBytes = modelData.buffer.asUint8List();

    _isolate = await Isolate.spawn(
        imageProcessor, IsolateInitData(_mainReceivePort.sendPort, modelBytes));

    _mainReceivePort.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
        if (!_isolateReadyCompleter.isCompleted) {
          _isolateReadyCompleter.complete();
        }
      } else if (message is Map<String, dynamic>) {
        _performOcr(message);
      } else {
        _isDetecting = false;
      }
    });
  }

  Future<void> _performOcr(Map<String, dynamic> yoloResults) async {
    final List<dynamic> detections = yoloResults['detections'];
    final img.Image? rotatedImage = yoloResults['image'];

    if (rotatedImage == null || detections.isEmpty) {
       if(mounted) setState(() => _recognitions = []);
       _isDetecting = false;
       return;
    }

    final bestDetection = detections.first;

    const int inputWidth = 640;
    const int inputHeight = 640;

    final rect = bestDetection['rect'] as Map<dynamic, dynamic>;
    final double scaleX = rotatedImage.width / inputWidth;
    final double scaleY = rotatedImage.height / inputHeight;

    const double padding = 1.1; 
    final cropX = (rect['left'] * scaleX).toInt().clamp(0, rotatedImage.width);
    final cropY = (rect['top'] * scaleY).toInt().clamp(0, rotatedImage.height);
    final cropWidth = (rect['width'] * scaleX * padding).toInt().clamp(0, rotatedImage.width - cropX);
    final cropHeight = (rect['height'] * scaleY * padding).toInt().clamp(0, rotatedImage.height - cropY);

    final plateImage = img.copyCrop(rotatedImage, x: cropX, y: cropY, width: cropWidth, height: cropHeight);

    // ✅✅✅ THE FIX IS HERE ✅✅✅
    // Resize to a fixed HEIGHT. This ensures characters are tall and clear,
    // which is better for OCR accuracy, while still reducing the overall pixel count for performance.
    final img.Image resizedPlateImage = img.copyResize(plateImage, height: 120);

    final Uint8List rgbaBytes = resizedPlateImage.toUint8List();
    final Uint8List bgraBytes = Uint8List(rgbaBytes.length);
    for (int i = 0; i < rgbaBytes.length; i += 4) {
      bgraBytes[i] = rgbaBytes[i + 2];
      bgraBytes[i + 1] = rgbaBytes[i + 1];
      bgraBytes[i + 2] = rgbaBytes[i];
      bgraBytes[i + 3] = rgbaBytes[i + 3];
    }

    final inputImage = InputImage.fromBytes(
      bytes: bgraBytes,
      metadata: InputImageMetadata(
        size: Size(resizedPlateImage.width.toDouble(), resizedPlateImage.height.toDouble()),
        rotation: InputImageRotation.rotation0deg,
        format: InputImageFormat.bgra8888,
        bytesPerRow: resizedPlateImage.width * 4,
      ),
    );

    final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);
    bestDetection['text'] = recognizedText.text.replaceAll(RegExp(r'[\s\n]'), '').toUpperCase();

    if (mounted) {
      List<Map<String, dynamic>> processedRecognitions = [];
      for (var item in detections) {
        final rectMap = item['rect'] as Map<dynamic, dynamic>;
        processedRecognitions.add({
          "rect": Rect.fromLTWH(rectMap['left'], rectMap['top'], rectMap['width'], rectMap['height']),
          "confidence": item['confidence'],
          "text": item['text'] ?? '',
        });
      }

      String latestPlateText = 'Scanning...';
      if ((bestDetection['text'] as String).isNotEmpty) {
        latestPlateText = bestDetection['text'];
      }

      setState(() {
        _recognitions = processedRecognitions;
        _recognizedPlateText = latestPlateText;
      });
    }
    
    _isDetecting = false;
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    // Use 'high' resolution as the best balance of accuracy and performance.
    _cameraController =
        CameraController(cameras[0], ResolutionPreset.high, enableAudio: false);
    await _cameraController!.initialize();
    if (!mounted) return;

    _cameraController!.startImageStream((CameraImage image) {
      _frameCounter++;
      if (_isDetecting || _frameCounter % _frameSkip != 0) {
        return;
      }
      
      _isDetecting = true;
      _isolateSendPort?.send(IsolateInferenceData(
        image.planes.map((plane) => plane.bytes).toList(),
        image.height,
        image.width,
        image.planes[1].bytesPerRow,
        image.planes[1].bytesPerPixel ?? 1,
      ));
    });
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _isolate?.kill(priority: Isolate.immediate);
    _mainReceivePort.close();
    _textRecognizer.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
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
                if (_recognitions != null)
                  CustomPaint(
                    painter: BoundingBoxPainter(
                      recognitions: _recognitions!,
                      modelInputSize: const Size(640, 640),
                      previewScreenSize: Size(screenSize.width, screenSize.width),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _recognizedPlateText,
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

// ===================================================
// --- Responsive BoundingBoxPainter
// ===================================================
class BoundingBoxPainter extends CustomPainter {
  final List<dynamic> recognitions;
  final Size modelInputSize;
  final Size previewScreenSize;

  BoundingBoxPainter({
    required this.recognitions,
    required this.modelInputSize,
    required this.previewScreenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = previewScreenSize.width / modelInputSize.width;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.red;

    for (var recognition in recognitions) {
      final rect = recognition['rect'] as Rect;
      final scaledRect = Rect.fromLTWH(
        rect.left * scale,
        rect.top * scale,
        rect.width * scale,
        rect.height * scale,
      );
      canvas.drawRect(scaledRect, paint);

      final ocrText = recognition['text'] as String?;
      final confidence = (recognition['confidence'] * 100).toStringAsFixed(0);
      
      String displayText;
      if (ocrText != null && ocrText.isNotEmpty) {
        displayText = '$ocrText ($confidence%)';
      } else {
        displayText = 'Plate ($confidence%)';
      }

      final textPainter = TextPainter(
        text: TextSpan(
          text: displayText,
          style: TextStyle(
            color: Colors.white,
            fontSize: 16.0,
            backgroundColor: (ocrText != null && ocrText.isNotEmpty)
                ? Colors.green.withOpacity(0.8)
                : Colors.red.withOpacity(0.8),
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      );
      
      textPainter.layout(minWidth: 0, maxWidth: previewScreenSize.width);
      textPainter.paint(canvas, Offset(scaledRect.left, scaledRect.bottom + 5));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}