import 'package:bitbox/bitbox.dart' as Bitbox;

class Transaction {
  final int id;
  final String txid;
  int confirmations;
  final DateTime time;
  final Map<String, int> addresses = <String, int>{};

  int get value {
    int valueToReturn = 0;
    addresses.forEach((key, value) {valueToReturn += value;});
    return valueToReturn;
  }

  Transaction(this.id, this.txid, this.time);

  Transaction.fromDb(Map row) :
      id = row["id"],
      txid = row["txid"],
      time = DateTime.fromMillisecondsSinceEpoch(row["time"]) {
    addresses["cash_addr"] = row["value"];
  }

  Future<Map> getDetails() async => Bitbox.Transaction.details(id);
}