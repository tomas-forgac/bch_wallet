import 'dart:convert';

import 'package:bch_wallet/bch_wallet.dart';
import 'package:bitbox/bitbox.dart' as Bitbox;
import 'package:sqflite/sqflite.dart' as sql;

import 'database.dart';

class Address {
  int id;
  final int walletId;
  final int accountId;
  final bool change;
  final int childNo;
  final String cashAddr;
  int get balance => confirmedBalance + unconfirmedBalance;
  int confirmedBalance = 0;
  int unconfirmedBalance = 0;

  List<Bitbox.Utxo> utxo;

  //TODO: implement this as a getter
  String get derivationPath => "";

  Address(this.childNo, this.cashAddr, this.walletId, this.accountId, this.change, {this.confirmedBalance = 0, this.unconfirmedBalance = 0});

  Address.fromJson(Map<String, dynamic> addressJson, this.childNo, this.walletId, this.accountId, this.change) :
      cashAddr = addressJson["cashAddr"],
//      balance = addressJson["confirmed_balance"] + addressJson["unconfirmed_balance"],
      unconfirmedBalance = addressJson["unconfirmedBalanceSat"],
      confirmedBalance = addressJson["balanceSat"];

  Address.fromDb(Map<String, dynamic> addressRow) :
      id = addressRow["id"],
      walletId = addressRow["wallet_id"],
      accountId = addressRow["account_no"],
      change = addressRow["change"] == 1,
      childNo = addressRow["child_no"],
      cashAddr = addressRow["cash_addr"],
      confirmedBalance = addressRow["balance"];

  Map<String, dynamic> toJson() => {
    "child_no" : childNo,
    "address" : cashAddr,
//    "balance" : balance,
    "balance" : confirmedBalance + unconfirmedBalance,
  };

  @override
  String toString() => jsonEncode(this.toJson());
//
//  int getBalance() {
//    return confirmedBalance + unconfirmedBalance;
//  }

  Future<int> receive([int expectedAmount]) async {
    expectedAmount ??= 1;
    int balance;
    do {
      await Future.delayed(Duration(milliseconds: 2000));
      balance = await updateBalanceFromBlockchain();
    } while (balance < expectedAmount);

    return balance;
  }

  /// TODO: update this comment
  /// Returns [address]' confirmed and unconfirmed balance in the following format:
  /// ```
  /// {
  ///     "confirmed": 0,
  ///     "unconfirmed": 0,
  /// }
  /// ````
  Future<int> updateBalanceFromBlockchain() async {
    Bitbox.Bitbox.setRestUrl(restUrl: _isTestnet(cashAddr) ? Bitbox.Bitbox.trestUrl : Bitbox.Bitbox.restUrl);

    final details = await Bitbox.Address.details(cashAddr);

    final oldBalance = balance;

    confirmedBalance = details["balanceSat"];
    unconfirmedBalance = details["unconfirmedBalanceSat"];

    if (oldBalance != balance) {
      final db = await Database.database;
      await _saveToDb(this, db);
      await _saveTransactions(this, db, details["transactions"]);

      final x = true;
    }

    return balance;
  }

  Future<List<Transaction>> getTransactions() async {
    final db = await Database.database;


  }

  static bool _isTestnet(String cashAddr) {
    if (cashAddr.startsWith("bchtest:")) {
      return true;
    } else if (cashAddr.startsWith("bitcoincash:")) {
      return false;
    }

    throw UnsupportedError("only mainnet and testnet supported");
  }

  static _saveToDb(Address address, sql.Database db) async {
    if (address.id != null) {
      await db.update("address", {"balance": address.balance}, where: "id = '${address.id}'");
    } else {
      address.id = await db.insert("address", {
        "wallet_id": address.walletId,
        "account_no": address.accountId,
        "change": address.change,
        "child_no": address.childNo,
        "cash_addr": address.cashAddr,
        "balance": address.balance
      });

      try {
        final wallet = (await BchWallet.getWalletList()).elementAt(address.walletId - 1);
        (await (await wallet.accounts)[address.accountId].addresses).add(address);
      } catch (e) {
        print("wallet ${address.walletId} or account ${address.accountId} doesn't exist - this shouldn't happen");
      }
    }
  }

  static void _saveTransactions(Address address, sql.Database db, List txIds) async {
    final txToFetch = List<String>.generate(txIds.length, (index) => txIds[index] as String);
//
//    final txQuery = "'" + txIds.join("', '") + "'";
//
//    final existingTxnQuery = await db.query("txn", where: "txid in ($txQuery)", columns: ["txid"]);
//
//    // TODO: this must be tested when I receive more to the alrready saved address
//    existingTxnQuery.forEach((row) {
//      txToFetch.remove(row["txid"]);
//    });

    final txDetails = await Bitbox.Transaction.details(txToFetch, false) as List;

    for (int i = 0; i < txDetails.length; i++) {
      final tx = txDetails[i];
      int id;

      final query = (await db.query("txn", columns: ["id"], where: "txid = ?", whereArgs: [tx["txid"]]));

      if (query.length > 0) {
        id = query.first["id"];
      } else {
        id = await db.insert("txn", {
          "wallet_id" : address.walletId,
          "txid": tx["txid"],
          "time": tx["time"] * 1000
        });
      }

      for (int j = 0; j < (tx["vin"] as List).length; j++) {
        if (tx["vin"][j]["cashAddress"] == address.cashAddr) {
          await db.insert("txn_address", {
            "txn_id": id,
            "address_id": address.id,
            "value": BchWallet.toSatoshi(tx["vin"][j]["value"] * -1),
          });
        }
      }

      for (int j = 0; j < (tx["vout"] as List).length; j++) {
        if (tx["vout"][j]["scriptPubKey"]["cashAddrs"].first == address.cashAddr) {
          await db.insert("txn_address", {
            "txn_id": id,
            "address_id": address.id,
            "value": BchWallet.toSatoshi(double.parse(tx["vout"][j]["value"])),
          });
        }
      };
    };
  }
}