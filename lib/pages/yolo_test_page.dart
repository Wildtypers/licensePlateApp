import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class YoloTestVisualPage extends StatefulWidget {
  const YoloTestVisualPage({super.key});

  @override
  State<YoloTestVisualPage> createState() => _YoloTestVisualPageState();
}

class _YoloTestVisualPageState extends State<YoloTestVisualPage> {
  late Interpreter interpreter;
  ui.Image? displayedImage;
  List<Rect> boxes = [];
  List<String> labels = [];

  @override
  void initState() {
    super.initState();
    runYoloTest();
  }

  Future<void> runYoloTest() async {
    try {
      // 1️⃣ Load TFLite model
      interpreter = await Interpreter.fromAsset('assets/yolov8n_float32.tflite');
      print("Model loaded successfully!");

      // 2️⃣ Load test image from assets
      ByteData imageData = await rootBundle.load('assets/car2.jpg');
      Uint8List bytes = imageData.buffer.asUint8List();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) {
        print("Failed to decode image");
        return;
      }

      // Resize to model input
      img.Image resized = img.copyResize(image, width: 640, height: 640);

      // Convert to Float32List
      Float32List input = imageToFloat32(resized);
      var inputTensor = input.reshape([1, 640, 640, 3]);

      // Prepare output for [1, 5, 8400] shape
      var output = List.generate(1, (_) => List.generate(5, (_) => List.filled(8400, 0.0)));

      // Run inference
      interpreter.run(inputTensor, output);
      print("Inference complete!");

      // Collect boxes and labels
      List<Rect> newBoxes = [];
      List<String> newLabels = [];

      for (int i = 0; i < 8400; i++) {
        double x = output[0][0][i];
        double y = output[0][1][i];
        double w = output[0][2][i];
        double h = output[0][3][i];
        double confidence = output[0][4][i];

        if (confidence > 0.50) { // filter low-confidence detections
          double left = (x - w / 2) * resized.width;
          double top = (y - h / 2) * resized.height;
          double width = w * resized.width;
          double height = h * resized.height;

          newBoxes.add(Rect.fromLTWH(left, top, width, height));
          newLabels.add("Object ${(confidence * 100).toStringAsFixed(0)}%");
        }
      }

      // Convert resized image to ui.Image for display
      ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(img.encodePng(resized));
      ui.ImageDescriptor id = await ui.ImageDescriptor.encoded(buffer);
      ui.Codec codec = await id.instantiateCodec();
      ui.FrameInfo fi = await codec.getNextFrame();

      setState(() {
        displayedImage = fi.image;
        boxes = newBoxes;
        labels = newLabels;
      });
    } catch (e) {
      print("Error: $e");
    }
  }

  Float32List imageToFloat32(img.Image image) {
    final int width = image.width;
    final int height = image.height;
    final Float32List converted = Float32List(width * height * 3);
    int index = 0;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        var pixel = image.getPixelSafe(x, y);
        int r = pixel.r.toInt();
        int g = pixel.g.toInt();
        int b = pixel.b.toInt();

        converted[index++] = r / 255.0;
        converted[index++] = g / 255.0;
        converted[index++] = b / 255.0;
      }
    }
    return converted;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('YOLOv8n Test Visual')),
      body: Center(
        child: displayedImage == null
            ? const CircularProgressIndicator()
            : FittedBox(
                child: SizedBox(
                  width: displayedImage!.width.toDouble(),
                  height: displayedImage!.height.toDouble(),
                  child: CustomPaint(
                    painter: BoundingBoxPainter(
                      image: displayedImage!,
                      boxes: boxes,
                      labels: labels,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class BoundingBoxPainter extends CustomPainter {
  final ui.Image image;
  final List<Rect> boxes;
  final List<String> labels;

  BoundingBoxPainter({
    required this.image,
    required this.boxes,
    required this.labels,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw the image
    paintImage(canvas: canvas, rect: Offset.zero & size, image: image, fit: BoxFit.fill);

    // Draw boxes
    final paint = Paint()
      ..color = Colors.red
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (int i = 0; i < boxes.length; i++) {
      final box = boxes[i];
      canvas.drawRect(box, paint);

      final textSpan = TextSpan(
        text: labels[i],
        style: const TextStyle(color: Colors.red, fontSize: 16),
      );
      textPainter.text = textSpan;
      textPainter.layout();
      textPainter.paint(canvas, Offset(box.left, box.top - 20));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
