import 'dart:isolate';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'dart:ui' as ui;
import 'dart:typed_data';


// ===============================
//  Data classes (same as before)
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
// --- Isolate function for YOLO inference ---
// ===================================================
void imageProcessor(IsolateInitData initData) async {
  final mainSendPort = initData.mainSendPort;
  final isolateReceivePort = ReceivePort();
  mainSendPort.send(isolateReceivePort.sendPort);


  Interpreter? interpreter;
  try {
    interpreter = Interpreter.fromBuffer(initData.modelData);
    print("✅ Isolate: Model loaded successfully");
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
      if (rgbImage == null) continue;


      // Rotate and resize to model input
      final rotated = img.copyRotate(rgbImage, angle: 90);
      final resized =
          img.copyResize(rotated, width: inputWidth, height: inputHeight);


      // Normalize input
      final input = Float32List(inputWidth * inputHeight * 3);
      int idx = 0;
      for (final pixel in resized) {
        input[idx++] = pixel.r / 255.0;
        input[idx++] = pixel.g / 255.0;
        input[idx++] = pixel.b / 255.0;
      }


      final shapedInput = input.reshape([1, inputHeight, inputWidth, 3]);
      final output =
          List.filled(outputShape.reduce((a, b) => a * b), 0.0).reshape(outputShape);


      interpreter.run(shapedInput, output);


      List<Map<String, dynamic>> recognitions = [];
      double maxConf = 0;


      for (int i = 0; i < numDetections; i++) {
        final conf = output[0][4][i];
        if (conf > maxConf) maxConf = conf;


        if (conf > 0.2) {
          final cx = output[0][0][i];
          final cy = output[0][1][i];
          final w = output[0][2][i];
          final h = output[0][3][i];


          final left = (cx - w / 2) * inputWidth;
          final top = (cy - h / 2) * inputHeight;
          final width = w * inputWidth;
          final height = h * inputHeight;


          recognitions.add({
            "rect": {"left": left, "top": top, "width": width, "height": height},
            "label": "Plate",
            "confidence": conf,
          });
        }
      }


      print("📊 Isolate: Highest confidence = ${(maxConf * 100).toStringAsFixed(2)}% "
          "(${recognitions.length} detections)");


      mainSendPort.send(recognitions);
    } catch (e) {
      print("❌ Isolate: Error during processing: $e");
      mainSendPort.send([]);
    }
  }
}


// ===================================================
// --- Convert YUV420 → RGB ---
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
// --- Main Page (Responsive full-screen preview) ---
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
      } else if (message is List) {
        List<Map<String, dynamic>> processedRecognitions = [];
        for (var item in message) {
          final rectMap = item['rect'] as Map<dynamic, dynamic>;
          processedRecognitions.add({
            "rect": Rect.fromLTWH(rectMap['left'], rectMap['top'],
                rectMap['width'], rectMap['height']),
            "label": item['label'],
            "confidence": item['confidence'],
          });
        }
        if (mounted) {
          setState(() {
            _recognitions = processedRecognitions;
          });
        }
      }
      _isDetecting = false;
    });
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    _cameraController =
        CameraController(cameras[0], ResolutionPreset.veryHigh, enableAudio: false);
    await _cameraController!.initialize();
    if (!mounted) return;

    _cameraController!.startImageStream((CameraImage image) {
      if (_isolateSendPort != null && !_isDetecting) {
        _isDetecting = true;
        _isolateSendPort!.send(IsolateInferenceData(
          image.planes.map((plane) => plane.bytes).toList(),
          image.height,
          image.width,
          image.planes[1].bytesPerRow,
          image.planes[1].bytesPerPixel ?? 1,
        ));
      }
    });
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _isolate?.kill(priority: Isolate.immediate);
    _mainReceivePort.close();
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
        height: screenSize.width, // This creates the square constraint
        
        // ✅ Wrap the Stack with a ClipRect. This is the crucial fix.
        // It will clip the overflowing parts of the CameraPreview.
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Camera preview will now be clipped to the square SizedBox
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: previewSize.height,
                  height: previewSize.width,
                  child: CameraPreview(_cameraController!),
                ),
              ),

              // Draw bounding boxes
              if (_recognitions != null)
                CustomPaint(
                  painter: BoundingBoxPainter(
                    recognitions: _recognitions!,
                    modelInputSize: const Size(640, 640),
                    previewScreenSize: Size(screenSize.width, screenSize.width),
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
// --- Responsive Bounding Box Painter ---
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

      // ✅ CORRECTED LOGIC: Simply scale the coordinates. No rotation needed.
      // The coordinate system of the model (after your 90-degree rotation)
      // and the coordinate system of the canvas are now the same.
      final double left = rect.left * scale;
      final double top = rect.top * scale;
      final double width = rect.width * scale;
      final double height = rect.height * scale;

      final scaledRect = Rect.fromLTWH(left, top, width, height);

      // Draw the scaled rectangle
      canvas.drawRect(scaledRect, paint);

      final textPainter = TextPainter(
        text: TextSpan(
          text:
              '${recognition['label']} ${(recognition['confidence'] * 100).toStringAsFixed(0)}%',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14.0,
            backgroundColor: Colors.red,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      );
      textPainter.layout(minWidth: 0, maxWidth: previewScreenSize.width);
      // Use the new scaledRect coordinates to position the label
      textPainter.paint(canvas, Offset(scaledRect.left, scaledRect.top - 20));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}