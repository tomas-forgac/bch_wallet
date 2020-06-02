import 'package:bitbox/bitbox.dart' as Bitbox;

/// Wrapper for basic information about a transaction in or out of an account
class Transaction {
  /// internal transaction record's id
  final int id;
  /// transaction identified in the network
  final String txid;
  /// number of confirmations
  int confirmations;
  /// date/time when the transaction was broadcasted to the network
  final DateTime time;
  /// list of addresses used in the trnasactions and their value changes.
  /// * If the value (in satoshis) is positive, the address received the balance
  /// in this transaction.
  /// * If it's negative, the balance was sent from the address
  final Map<String, int> addresses = <String, int>{};

  /// overall value of which this transaction changed balance of the account
  int get value {
    int valueToReturn = 0;
    addresses.forEach((key, value) {valueToReturn += value;});
    return valueToReturn;
  }

  Transaction(this.id, this.txid, this.time);

  /// creates a transaction from the db row.
  Transaction.fromDb(Map row) :
      id = row["id"],
      txid = row["txid"],
      time = DateTime.fromMillisecondsSinceEpoch(row["time"]) {
    addresses["cash_addr"] = row["value"];
  }

  /// Return details of the transaction from Bitbox
  /// The details are returned parsed from the format defined here:
  /// https://developer.bitcoin.com/bitbox/docs/transaction#details
  Future<Map> getDetails() async => await Bitbox.Transaction.details(id);
}