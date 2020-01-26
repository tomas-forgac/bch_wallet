class Account {
  final int id;
  final String name;

  Account(this.id, this.name);

  Account.fromDbRow(row) :
    id = row["account_id"],
    name = row["name"];

  //TODO: is there a case for this?
//  Future<String> getXPub() {
//
//  }
}