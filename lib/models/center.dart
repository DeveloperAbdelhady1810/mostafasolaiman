class AttendanceCenter {
  final int id;
  final String name;
  final String? address;

  AttendanceCenter({required this.id, required this.name, this.address});

  factory AttendanceCenter.fromJson(Map<String, dynamic> json) {
    return AttendanceCenter(
      id: json['id'] as int,
      name: json['name'] as String,
      address: json['address'] as String?,
    );
  }
}
