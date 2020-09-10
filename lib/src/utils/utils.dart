import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../bch_wallet.dart';
import 'package:sqflite/sqflite.dart' as sql;
import 'package:bitbox/bitbox.dart' as Bitbox;

Future<List<Transaction>> saveTransactions(Address address, sql.Database db, List txs) async {
  List txDetails = [];

  final txToFetch = <String>[];
  for (int i = 0; i < txs.length; i++) {
    txToFetch.add(txs[i] as String);
    if (txToFetch.length == 10 || i == txs.length - 1) {
      txDetails.addAll(await Bitbox.Transaction.details(txToFetch, false));
      txToFetch.clear();
    }
  }

  final txToReturn = <Transaction>[];

  for (int i = 0; i < txDetails.length; i++) {
    final tx = txDetails[i] as Map;
    int id;

    final query = await db.query("txn", columns: ["id"], where: "txid = ? AND wallet_id = ?",
      whereArgs: [tx["txid"], address.walletId]);

    if (query.length > 0) {
      id = query.first["id"];
      if ((await db.query("txn_address", where: "txn_id = ? AND address_id = ?", whereArgs: [id, address.id]))
        .length > 0) {
        continue;
      }
    } else {
      id = await db.insert("txn", {
        "wallet_id" : address.walletId,
        "txid": tx["txid"],
        "time": tx["time"] * 1000
      });
    }

    final transaction = Transaction(id, tx["txid"], DateTime.fromMillisecondsSinceEpoch(tx["time"] * 1000));

    for (int j = 0; j < (tx["vin"] as List).length; j++) {
      if (tx["vin"][j]["cashAddress"] == address.cashAddr) {
        transaction.addresses[address.cashAddr] = tx["vin"][j]["value"] * -1;
        await db.insert("txn_address", {
          "txn_id": id,
          "address_id": address.id,
          "value": tx["vin"][j]["value"] * -1,
        });
      }
    }

    for (int j = 0; j < (tx["vout"] as List).length; j++) {
      if (tx["vout"][j]["scriptPubKey"]["cashAddrs"].first == address.cashAddr) {
        transaction.addresses[address.cashAddr] = BchWallet.toSatoshi(double.parse(tx["vout"][j]["value"]));
        await db.insert("txn_address", {
          "txn_id": id,
          "address_id": address.id,
          "value": BchWallet.toSatoshi(double.parse(tx["vout"][j]["value"])),
        });
      }
    }

    transaction.confirmations = 0;
    txToReturn.add(transaction);
  }

  return txToReturn;
}

Future<bool> deleteWallet(int walletId, sql.Database db, [bool withRecord = false, String mnemonicStorageKey]) async {
  await db.rawDelete("DELETE FROM txn_address WHERE address_id IN (SELECT id FROM address WHERE wallet_id = $walletId)");
  db.delete("txn", where: "wallet_id = $walletId");
  db.delete("address", where: "wallet_id = $walletId");
  db.delete("account", where: "wallet_id = $walletId");

  if (withRecord) {
    db.delete("wallet", where: "id = $walletId");
    FlutterSecureStorage().delete(key: "${mnemonicStorageKey}_$walletId");
  }

  return true;
}

// sets testnet rest api. Typically this method doesn't need to be used if working only with internal wallet
setTestNet(bool testnet) {
  Bitbox.Bitbox.setRestUrl(testnet ? Bitbox.Bitbox.trestUrl : Bitbox.Bitbox.restUrl);
}
