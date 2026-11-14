import 'package:flutter/material.dart';
import 'package:workspace_member/member.dart';
import 'package:workspace_member_b/member_b.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await member();
  await memberB();
  runApp(const MaterialApp(home: Text('workspace')));
}
