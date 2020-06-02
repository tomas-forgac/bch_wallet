import 'dart:convert';

import 'package:bch_wallet/bch_wallet.dart';
import 'package:bch_wallet/src/utils/utils.dart';
import 'package:bitbox/bitbox.dart' as Bitbox;
import 'package:sqflite/sqflite.dart' as sql;

import 'utils/database.dart';

/// Stores information about and provides function to work with an address
class Address {
  /// addresses database id (optional in case a new instance is created before it is saved to the db
  int id;
  /// id of the wallet this address belongs to
  final int walletId;
  /// id of the account this address belongs to
  final int accountNo;
  /// is this change or primary address
  final bool change;
  /// derived child number
  final int childNo;
  /// cashAddr
  final String cashAddr;
  /// getter for all (confirmed and unconfirmed) balance
  int get balance => confirmedBalance + unconfirmedBalance;

  /// Balances in this library are always in satoshis.
  /// When the balance is retrieves from the internal storage, it is always considered confirmed.
  /// Call [updateBalanceFromBlockchain] to update [confirmedBalance] and [unconfirmedBalance]
  int confirmedBalance = 0;
  int unconfirmedBalance = 0;

  /// addresses utxos. It is filled by [Account.getUtxos] function
  List<Bitbox.Utxo> utxo;

  //TODO: implement this as a getter
  String get derivationPath => "";

  Address(this.childNo, this.cashAddr, this.walletId, this.accountNo, this.change,
    {this.confirmedBalance = 0, this.unconfirmedBalance = 0, this.id});

  /// Generates a new instance from Bitbox' Address json format
  Address.fromJson(Map<String, dynamic> addressJson, this.childNo, this.walletId, this.accountNo, this.change, {this.id}) :
      cashAddr = addressJson["cashAddress"],
//      balance = addressJson["confirmed_balance"] + addressJson["unconfirmed_balance"],
      unconfirmedBalance = addressJson["unconfirmedBalanceSat"],
      confirmedBalance = addressJson["balanceSat"];

  Map<String, dynamic> toJson() => {
    "child_no" : childNo,
    "address" : cashAddr,
    "balance" : balance,
  };

  @override
  String toString() => jsonEncode(this.toJson());

  /// waits for a balance to be received by the address.
  /// [expectedAmount] is in satoshis. If it is provided, it waits for the exact ot higher amount, otherwise any amount
  ///
  /// it will update [unconfirmedBalance] accordingly.
  /// returns a list of [Transaction] with the receiving transactions
  /// (typically just one, but to cover some special circumstances if the amount received in more than one transaction,
  /// it will return all of them).
  Future<List<Transaction>> receive([int expectedAmount]) async {
    expectedAmount ??= 1;
    if (expectedAmount < 0) {
      throw ArgumentError("expectedAmount must be a positive integer");
    }

    List<Transaction> transactions;

    do {
      //TODO: decrease this to 500 ms before releasing
      await Future.delayed(Duration(milliseconds: 5000));
      transactions = await updateBalanceFromBlockchain();
    } while (this.balance < expectedAmount);

    return transactions;
  }

  /// Updates this address' confirmed and unconfirmed balance from the blockchain.
  /// Returns a list of any new transactions
  Future<List<Transaction>> updateBalanceFromBlockchain() async {
    setTestNet(isTestnet(cashAddr));

    // get address details from Bitbox
    final details = await Bitbox.Address.details(cashAddr);

    // placeholder to compare the current to updated balance
    final oldBalance = balance;

    // update the address confirmed and unconfirmed balances
    confirmedBalance = details["balanceSat"];
    unconfirmedBalance = details["unconfirmedBalanceSat"];

    List<Transaction> txnsToReturn;

    // if the overall balance has changed, update the address and the transactions
    if (oldBalance != balance) {
      final db = await Database.database;
      await _saveToDb(this, db);

      txnsToReturn = await saveTransactions(this, db, details["transactions"]);
    }

    return txnsToReturn;
  }

  /// checks if the provided address is testnet or mainnet
  static bool isTestnet(String cashAddr) {
    if (cashAddr.startsWith("bchtest:")) {
      return true;
    } else if (cashAddr.startsWith("bitcoincash:")) {
      return false;
    }

    throw UnsupportedError("only mainnet and testnet supported");
  }

  // save the provided address to the db. if it has an id, it will update its db record.
  // If not, it will attempt to create a new record and update the id in the [address] instance
  static _saveToDb(Address address, sql.Database db) async {
    if (address.id != null) {
      await db.update("address", {"balance": address.balance}, where: "id = '${address.id}'");
    } else {
      address.id = await db.insert("address", {
        "wallet_id": address.walletId,
        "account_no": address.accountNo,
        "change": address.change,
        "child_no": address.childNo,
        "cash_addr": address.cashAddr,
        "balance": address.balance
      });

      try {
        final wallet = (await BchWallet.getWalletList()).elementAt(address.walletId - 1);
        (await (await wallet.accounts)[address.accountNo].addresses).add(address);
      } catch (e) {
        print("wallet ${address.walletId} or account ${address.accountNo} doesn't exist - this shouldn't happen");
      }
    }
  }
}