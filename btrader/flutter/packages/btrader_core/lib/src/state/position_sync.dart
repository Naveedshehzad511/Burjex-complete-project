import '../models/position.dart';

/// True when a WS payload means the ticket is actually CLOSED (not CLOSE_PENDING).
bool positionEventIsClosed(Map<String, dynamic> data) {
  final id = '${data['id'] ?? data['positionId'] ?? ''}';
  if (id.isEmpty) return false;
  final status = '${data['status'] ?? ''}'.toUpperCase();
  if (status == 'CLOSE_PENDING') return false;
  final book = '${data['book'] ?? ''}'.toLowerCase();
  final stateVal = '${data['state'] ?? ''}'.toLowerCase();
  final reason = '${data['reason'] ?? ''}'.toUpperCase();
  final event = '${data['event'] ?? ''}'.toLowerCase();
  return status == 'CLOSED' ||
      book == 'closed' ||
      stateVal == 'closed' ||
      data['closing'] == true ||
      event == 'position_closed' ||
      reason == 'SL_HIT' ||
      reason == 'TP_HIT';
}

bool staleOpenBlocked(String id, Map<String, dynamic> data, Set<String> closedIds) {
  if (id.isEmpty || !closedIds.contains(id)) return false;
  return !positionEventIsClosed(data);
}

/// Entry / SL / TP lines stay through CLOSE_PENDING; drop on actual close.
List<Position> overlayPositions(List<Position> src, Set<String> closedIds) {
  return [
    for (final p in src)
      if (!closedIds.contains(p.id) && _workingStatus(p.status)) p,
  ];
}

bool _workingStatus(String status) {
  final s = status.toUpperCase();
  return s == 'OPEN' || s == 'CLOSE_PENDING' || s.isEmpty;
}

/// Server open-position snapshot is the reconnect source of truth.
List<Position> reconcileOpenSnapshot(
  List<Position> snapshot,
  Set<String> closedIds,
) {
  return overlayPositions(snapshot, closedIds);
}

/// Merge a live WS row into the overlay list without resurrecting CLOSED ids.
List<Position> upsertLivePosition(
  List<Position> current,
  Position next,
  Set<String> closedIds,
) {
  if (closedIds.contains(next.id) || !_workingStatus(next.status)) {
    return overlayPositions(current.where((p) => p.id != next.id).toList(), closedIds);
  }
  final out = [for (final p in current) if (p.id != next.id) p, next];
  return overlayPositions(out, closedIds);
}

List<Position> removeLivePosition(List<Position> current, String id) {
  return [for (final p in current) if (p.id != id) p];
}

Position? positionFromWs(Map<String, dynamic> data) {
  final id = '${data['id'] ?? data['positionId'] ?? ''}';
  if (id.isEmpty) return null;
  try {
    return Position.fromJson({
      ...data,
      'id': id,
      'status': data['status'] ?? 'OPEN',
      'side': data['side'] ?? 'BUY',
      'volume': data['volume'] ?? 0,
      'openPrice': data['openPrice'] ?? 0,
      'profit': data['profit'] ?? 0,
      'swap': data['swap'] ?? 0,
      'symbol': data['symbol'] ?? '',
      'accountId': data['accountId'] ?? '',
    });
  } catch (_) {
    return null;
  }
}
