import 'package:license_app/models/License.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseService {
  static Database? _db;
  static final DatabaseService instance = DatabaseService._constructor();

  final String _licencePlateTable = "license_plates";
  final String _licenseIdColumnName = "id";
  final String _licenseContentColumnName = "license_plate";
  final String _licenseCarType = "car_type";

  DatabaseService._constructor();

  Future<Database> get database async{
    if (_db != null) return _db!;
    _db = await getDatabase();
    return _db!;
  }

  Future<Database> getDatabase() async {
    final databaseDirPath = await getDatabasesPath();
    final databasePath = join(databaseDirPath, "master_db.db");
    final database = await openDatabase(
      databasePath,
      version: 1,
      onCreate: (db, version) {
        db.execute('''
          CREATE TABLE $_licencePlateTable (
            $_licenseIdColumnName INTEGER PRIMARY KEY,
            $_licenseContentColumnName TEXT NOT NULL,
            $_licenseCarType TEXT NOT NULL
          )
        ''');
      },
    );
    return database;
  }

  void addCar(String licensePlates, String carType) async {
    final db = await database;
    await db.insert(_licencePlateTable, {
      _licenseContentColumnName: licensePlates,
      _licenseCarType: carType,
      },
    );
  }

  Future<List<License>> getCar() async {
    final db = await database;
    final data = await db.query(_licencePlateTable);
    List<License> car = data.map((e) => License(
      id: e[_licenseIdColumnName] as int,
      license: e[_licenseContentColumnName] as String,
      carType: e[_licenseCarType] as String)).toList();
    return car;
  }
}