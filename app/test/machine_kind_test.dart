import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';

void main() {
  test('stored machines without a kind stay SSH', () {
    final profile = MachineProfile.fromJson({'id': 'm', 'label': 'box', 'host': 'h', 'username': 'u'});
    expect(profile.kind, MachineKind.ssh);
  });

  test('local machines round-trip through storage', () {
    const local = MachineProfile(
      id: 'local-debian',
      label: 'Debian',
      host: 'local',
      username: 'local',
      kind: MachineKind.local,
    );
    final restored = MachineProfile.fromJson(local.toJson());
    expect(restored.kind, MachineKind.local);
    expect(restored.id, local.id);
    expect(restored.copyWith(label: 'Debian 13').kind, MachineKind.local);
  });
}
