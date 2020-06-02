import 'package:sqflite/sqflite.dart' as sql;
import 'package:path/path.dart';

class Database {
  static final Future<sql.Database> database = _connect();

  static Future<sql.Database> _connect() async {
    return sql.openDatabase(
      join(await sql.getDatabasesPath(), 'bch_wallet.db'),
      onCreate: (db, version) {
        db.execute("CREATE TABLE wallet (id INTEGER PRIMARY KEY, testnet BOOL NOT NULL DEFAULT false, name TEXT, derivation_path TEXT NOT NULL, password_hash TEXT)");
        db.execute("CREATE TABLE account (wallet_id INTEGER NOT NULL, account_no INT NOT NULL, name TEXT, xpub TEXT NOT NULL, PRIMARY KEY (wallet_id, account_no), FOREIGN KEY (wallet_id) REFERENCES wallet(id))");
        db.execute("CREATE TABLE address (id INTEGER PRIMARY KEY, wallet_id INT NOT NULL, account_no INT NOT NULL, change BOOL NOT NULL DEFAULT false, child_no INT NOT NULL, cash_addr TEXT NOT NULL, balance INT NOT NULL, FOREIGN KEY (wallet_id) REFERENCES wallet(id))");
          db.execute("CREATE TABLE txn (id INTEGER PRIMARY KEY, wallet_id INT NOT NULL, txid STRING NOT NULL, time INT NOT NULL, FOREIGN KEY (wallet_id) REFERENCES wallet(id))");
        db.execute("CREATE UNIQUE INDEX tdx_txid_wallet_id ON txn(txid, wallet_id)");
        db.execute("CREATE TABLE txn_address (txn_id INTEGER NOT NULL, address_id INTEGER NOT NULL, value INT NOT NULL, "
          "FOREIGN KEY (txn_id) REFERENCES txn(id), FOREIGN KEY (address_id) REFERENCES address(id))");
      },
      version: 1
    );
  }
}