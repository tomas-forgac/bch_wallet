import 'dart:convert';

import 'package:bch_wallet/bch_wallet.dart';
import 'package:bch_wallet/src/utils/utils.dart';
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

  Address.fromJson(Map<String, dynamic> addressJson, this.childNo, this.walletId, this.accountId, this.change, {this.id}) :
      cashAddr = addressJson["cashAddress"],
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
      await Future.delayed(Duration(milliseconds: 5000));
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
    Bitbox.Bitbox.setRestUrl(isTestnet(cashAddr) ? Bitbox.Bitbox.trestUrl : Bitbox.Bitbox.restUrl);

    final details = await Bitbox.Address.details(cashAddr);

    final oldBalance = balance;

    confirmedBalance = details["balanceSat"];
    unconfirmedBalance = details["unconfirmedBalanceSat"];

    if (oldBalance != balance) {
      final db = await Database.database;
      await _saveToDb(this, db);
      await saveTransactions(this, db, details["transactions"]);
    }

    return balance;
  }

  //TODO
  Future<List<Transaction>> getTransactions() async {
    final db = await Database.database;


  }

  static bool isTestnet(String cashAddr) {
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
}