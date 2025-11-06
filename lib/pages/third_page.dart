import 'package:flutter/material.dart';
import 'package:license_app/models/License.dart';
import 'package:license_app/services/database_service.dart';

class MyThirdPage extends StatefulWidget{
  const MyThirdPage({super.key});

  @override
  State<MyThirdPage> createState() => _MyThirdPageState();
}

class _MyThirdPageState extends State<MyThirdPage> {

  final DatabaseService _databaseservice = DatabaseService.instance;

  String? _license = null;
  String? _carType = null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: _addTaskButton(),
      body: _carsList(),
    );
  }

  Widget _addTaskButton() {
    return FloatingActionButton(
      onPressed: () {
        showDialog(
          context: context, 
          builder: (_) => AlertDialog(
            title: const Text("Add Car"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [TextField(
                onChanged: (value) {
                  setState(() {
                    _license = value;
                  });
                },
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: "License Plate"
                ),
              ), 
              TextField(
                onChanged: (value) {
                  setState(() {
                    _carType = value;
                  });
                },
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: "Input Car Type"
                ),
              ), 
              MaterialButton(
                color: Theme.of(context).colorScheme.primary,
                onPressed: () {
                  if (_license == null || _license == "" || _carType == null || _carType == "") return;
                  _databaseservice.addCar(_license!, _carType!);
                  setState(() {
                    _license = null;
                    _carType = null;
                  });
                  Navigator.of(context, rootNavigator: true).pop();
                },
                child: const Text(
                  "Done",
                  style: TextStyle(
                    color: Colors.white,
                  ))
              ),
              ]
            )
          ));
      },
      child: const Icon(
        Icons.add,
      ),
    );
  }
  Widget _carsList() {
    return FutureBuilder(future: _databaseservice.getCar(), builder: (context, snapshot) {
      return ListView.builder(
        itemCount: snapshot.data?.length ?? 0,
        itemBuilder: (context, index) {
          License car = snapshot.data![index];
          return ListTile(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(car.license, style: TextStyle(fontWeight: FontWeight.bold)),
                    SizedBox(width: 10), // optional spacing between items
                    Text(car.carType),
                  ],
                ),
              ],
            ),
          );
        });
    });
  }
}


  // @override
  // Widget build(BuildContext context) {
  //   return Scaffold(
  //     appBar: AppBar(
  //       automaticallyImplyLeading: false,
  //       title: Text("Upload Records"),
  //     ),
  //     body: Center(
  //       child: ElevatedButton(
  //         child: Text("Back to Home Page"),
  //         onPressed: () {
  //           Navigator.pop(context);
  //           }, 
  //         ),
  //       )
  //   );
  // }