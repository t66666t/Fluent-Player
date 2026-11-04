/// Serialises cloud quality switches so a slow earlier choice cannot win.
class CloudDriveQualitySwitch {
  var _ticket = 0;
  var switching = false;

  int begin() {
    switching = true;
    return ++_ticket;
  }

  bool isLatest(int ticket) => ticket == _ticket;

/// Only the request that is still current may clear the spinner.
  void finish(int ticket) {
    if (ticket == _ticket) switching = false;
  }
}

/// Finish the gate before telling listeners, so the spinner is already gone.
void publishCloudDriveQualityEnd({
  required CloudDriveQualitySwitch gate,
  required int ticket,
  required void Function() notify,
}) {
  gate.finish(ticket);
  notify();
}

/// Whether a prepared controller is allowed to replace the one on screen.
bool cloudDriveQualityCommitAllowed({
  required int ticket,
  required int latestTicket,
  required String itemId,
  required String? currentItemId,
}) {
  return ticket == latestTicket && itemId == currentItemId;
}
