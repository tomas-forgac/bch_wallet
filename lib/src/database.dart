import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class Database {
  static connect() async {
    openDatabase(
      join(await getDatabasesPath(), 'bch_wallet.db'),
      onCreate: (db, version) {
        db.execute("CREATE TABLE wallet (id INTEGER PRIMARY KEY, testnet bool DEFAULT false)");
      }
    );
  }
}