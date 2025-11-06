// import 'package:flutter/material.dart';
// import 'package:license_app/pages/yolo_test_page.dart';

// void main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//   runApp(const MaterialApp(home: YoloTestVisualPage()));
// }


import 'package:flutter/material.dart';
import 'package:license_app/pages/home_page.dart';
import 'package:camera/camera.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras(); // get list of available cameras
  runApp(MaterialApp(home: MyApp(cameras: cameras),));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.cameras});
  final List<CameraDescription> cameras;


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'License Plate Checker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: MyHomePage(title: 'License Plate Scanner', cameras: cameras),
    );
  }
}