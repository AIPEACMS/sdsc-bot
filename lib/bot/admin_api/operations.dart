part of '../admin_api.dart';

mixin _AdminApi3 on AdminApi {

  /// Toggles the admin flag only — the member tier (check/member/old) is
  /// left untouched, unlike [setTier] which clears admin on any non-admin
  /// tier. The console may also use this (e.g. stepping down as admin while
  /// remaining the console).
  Future<(int, Object)> _setUserAdmin(int id, String bodyText) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    final body = _jsonBody(bodyText);
    final admin = body['admin'];
    if (admin is! bool) {
      return (400, {'ok': false, 'error': 'expected {"admin": bool}'});
    }
    if (admin && user.memberTier == MemberTier.outMember) {
      return (400, {
        'ok': false,
        'error': 'out-members cannot be promoted to admin',
      });
    }
    if (!repo.updateAdmin(id, admin)) {
      return (
        409,
        {'ok': false, 'error': 'global admin role requires Telegram handoff'},
      );
    }
    final updated = repo.findUser(id)!;
    LogRing.log(
      'admin API: ${updated.name} ${admin ? 'granted' : 'stripped'} admin',
    );
    return (
      200,
      {
        'ok': true,
        'admin': admin,
        'tier': MemberTier.of(updated, isConsole: config.isConsole(id)),
      },
    );
  }

  /// Locations: approved + pending, each with its aliases.
  Map<String, Object?> _locationsBody() => {
    'ok': true,
    'approved': [for (final l in repo.approvedLocations()) _locationJson(l)],
    'pending': [for (final l in repo.pendingLocations()) _locationJson(l)],
  }

;

  static Map<String, Object?> _locationJson(LocationInfo l) => {
    'id': l.id,
    'key': l.key,
    'name': l.name,
    'aliases': l.aliases,
    'status': l.status,
  }

;

  /// Adds (or approves) a location by name. Used by the console app in place
  /// of the chat `/addlocation`.
  Future<(int, Object)> _createLocation(String bodyText) async {
    final body = _jsonBody(bodyText);
    final name = (body['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      return (400, {'ok': false, 'error': 'expected {"name": "..."}'});
    }
    final aliases =
        (body['aliases'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final pending = repo
        .pendingLocations()
        .where((l) => l.name.toLowerCase() == name.toLowerCase())
        .toList();
    final LocationInfo loc;
    if (pending.isNotEmpty) {
      repo.approveLocation(pending.first.id, aliases: aliases);
      loc = repo.locationByKey(pending.first.key)!;
    } else {
      loc = repo.addLocation(name, aliases: aliases);
    }
    LogRing.log('admin API: location added: ${loc.name}');
    await onLocationApproved?.call(loc);
    return (200, {'ok': true, 'location': _locationJson(loc)});
  }

  /// Approves a pending location, optionally renaming it and setting aliases.
  Future<(int, Object)> _approveLocation(int id, String bodyText) async {
    if (repo.locationById(id) == null) {
      return (404, {'ok': false, 'error': 'no such location'});
    }
    final body = _jsonBody(bodyText);
    final name = body['name'] as String?;
    final aliases = (body['aliases'] as List?)?.whereType<String>().toList();
    repo.approveLocation(id, name: name, aliases: aliases);
    final loc = repo.locationById(id)!;
    LogRing.log('admin API: location approved: ${loc.name}');
    await onLocationApproved?.call(loc);
    return (200, {'ok': true, 'location': _locationJson(loc)});
  }

  /// Appoints or removes the singleton global admin, the chat-side equivalent
  /// of `/addg` / `/rmg`. The repo enforces the one-global-admin rule inside a
  /// transaction: appointing fails while another global admin exists, and
  /// removing returns the target to a regular member and dissolves their
  /// group.
  Future<(int, Object)> _setUserGlobalAdmin(int id, String bodyText) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    final body = _jsonBody(bodyText);
    final gadmin = body['gadmin'];
    if (gadmin is! bool) {
      return (400, {'ok': false, 'error': 'expected {"gadmin": bool}'});
    }

    if (gadmin) {
      final result = repo.appointGlobalAdmin(id);
      if (result == GlobalAdminResult.alreadyExists) {
        return (409, {'ok': false, 'error': 'a global admin already exists'});
      }
      if (result == GlobalAdminResult.noSuchUser) {
        return (404, {'ok': false, 'error': 'no such user'});
      }
      if (result == GlobalAdminResult.outMember) {
        return (
          400,
          {'ok': false, 'error': 'out-members cannot be global admins'},
        );
      }
      final updated = repo.findUser(id)!;
      LogRing.log('admin API: ${updated.name} appointed global admin');
      return (
        200,
        {
          'ok': true,
          'gadmin': true,
          'tier': MemberTier.of(updated, isConsole: config.isConsole(id)),
        },
      );
    }

    if (!repo.removeGlobalAdmin(id)) {
      return (409, {'ok': false, 'error': 'that user is not the global admin'});
    }
    final updated = repo.findUser(id)!;
    LogRing.log('admin API: ${updated.name} removed as global admin');
    return (
      200,
      {
        'ok': true,
        'gadmin': false,
        'tier': MemberTier.of(updated, isConsole: config.isConsole(id)),
      },
    );
  }

  Future<(int, Object)> _setUserExp(int id, String bodyText) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    if (user.memberTier == MemberTier.outMember) {
      return (400, {'ok': false, 'error': 'out-members have no experience control'});
    }
    final body = _jsonBody(bodyText);
    final exp = (body['exp'] as String?) ?? '';
    if (exp != 'experienced' && exp != 'newbie') {
      return (
        400,
        {'ok': false, 'error': 'expected {"exp": "experienced"|"newbie"}'},
      );
    }
    repo.updateExperience(
      id,
      exp == 'experienced' ? Experience.experienced : Experience.newbie,
    );
    LogRing.log('admin API: ${user.name} exp → $exp');
    return (200, {'ok': true, 'exp': exp});
  }

  /// Manual group change for a member: move to another admin-led group, or
  /// remove them from their group (`group: ""`). Blocked for admins — they
  /// own their group and cannot be moved until demoted.
  Future<(int, Object)> _setUserGroup(int id, String bodyText) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    if (user.memberTier == MemberTier.outMember) {
      return (400, {'ok': false, 'error': 'out-members are not assigned to groups'});
    }
    if (user.isAdmin || user.isGlobalAdmin) {
      return (
        400,
        {'ok': false, 'error': 'admin owns their group — demote first'},
      );
    }
    final body = _jsonBody(bodyText);
    final group = (body['group'] as String?) ?? '';
    if (group.isNotEmpty && group != user.group) {
      final adminGroups = repo
          .allUsers()
          .where((u) =>
              (u.isAdmin || u.isGlobalAdmin) && u.group.isNotEmpty)
          .map((u) => u.group)
          .toSet();
      if (!adminGroups.contains(group)) {
        return (400, {'ok': false, 'error': 'unknown group'});
      }
    }
    repo.setGroup(id, group);
    LogRing.log(
      'admin API: ${user.name} group → ${group.isEmpty ? '(none)' : group}',
    );
    return (200, {'ok': true, 'group': group});
  }

  /// Randomly and evenly assigns members without a group to the admins'
  /// groups (see [Repo.autoAssignGroups]).
  Future<(int, Object)> _assignGroups() async {
    final counts = repo.autoAssignGroups();
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    LogRing.log(
      'admin API: auto-assign groups → $total members '
      'across ${counts.length} groups',
    );
    return (200, {'ok': true, 'assigned': total, 'groups': counts.length});
  }

}
