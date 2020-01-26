import 'dart:convert';

class Address {
  final int childNo;
  final String cashAddr;
  int balance = 0;
  int confirmedBalance = 0;
  int unconfirmedBalance = 0;

  String derivationPath;

  Address(this.childNo, this.cashAddr, this.balance, [this.confirmedBalance, this.unconfirmedBalance]);

  Address.fromJson(Map<String, dynamic> addressJson) :
      childNo = addressJson["child_no"],
      cashAddr = addressJson["cash_addr"],
      balance = addressJson["confirmed_balance"] + addressJson["unconfirmed_balance"],
      unconfirmedBalance = addressJson["unconfirmed_balance"],
      confirmedBalance = addressJson["confirmed_balance"];

  Map<String, dynamic> toJson() => {
    "child_no" : childNo,
    "address" : cashAddr,
    "balance" : balance,
  };

  @override
  String toString() => jsonEncode(this.toJson());
}