part of '../models.dart';

class LocationInfo {
  final int id;
  final String key; // stable id used on sessions/slots (e.g. 'pasirRis')
  final String name; // display name, e.g. 'Pasir Ris'
  final List<String> aliases; // extra spellings the parser accepts
  final String status; // 'approved' | 'pending'
  final int? requestedBy;

  const LocationInfo({
    required this.id,
    required this.key,
    required this.name,
    required this.aliases,
    required this.status,
    this.requestedBy,
  });

  bool get isApproved => status == 'approved';

  factory LocationInfo.fromRow(Map<String, Object?> row) => LocationInfo(
    id: row['id'] as int,
    key: row['key'] as String,
    name: row['name'] as String,
    aliases: ((jsonDecode((row['aliases'] as String?) ?? '[]')) as List)
        .whereType<String>()
        .toList(),
    status: (row['status'] as String?) ?? 'approved',
    requestedBy: row['requested_by'] as int?,
  );
}
