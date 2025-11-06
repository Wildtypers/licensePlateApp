import 'package:flutter/material.dart';
import 'package:license_app/pages/second_page.dart';
import 'package:license_app/pages/third_page.dart';
import 'package:camera/camera.dart';

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title, required this.cameras});

  final String title;
  final List<CameraDescription> cameras;
  
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(

        backgroundColor: Theme.of(context).colorScheme.inversePrimary,

        title: Text(widget.title),
      ),
      body: Center(
        child: Padding(padding: EdgeInsets.all(50),
        child: Column (
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: EdgeInsets.only(bottom: 20),
              child: Column(
                children: [
                  Icon(
                    Icons.camera_alt,
                    color: Colors.black,
                    size: 50,
                  ),
                  Text("Phone Scanner",
                    style: TextStyle(fontSize:24, fontWeight: FontWeight.bold),
                  ),
                ]
              )  
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  child: Text("Phone Scanner"),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        // This is the correct line
                        builder: (context) => const MySecondPage(),
                      ),
                    );
                  }
                ),
                ElevatedButton(
                  child: Text("Upload Record"),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MyThirdPage()
                      )
                    );
                  },) 
              ],
            )
          ]    
        ) 
      ),
      ),
    );
  }
}