import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1. قم باستيراد الكلاس الصحيح
import 'package:attendance_app/main.dart'; // افترضنا أن الكلاس موجود في main.dart

void main() {
  testWidgets('App loads smoke test', (WidgetTester tester) async {
    // 2. استخدم اسم الكلاس الصحيح هنا
    // (بناءً على ملف pubspec.yaml الخاص بك [cite: 1gj/attendance_app/attendance_app-f6c4088d553fa25c49f572fbf6ddc8bb49548083/pubspec.yaml])
    await tester.pumpWidget(const AttendanceApp());

    // 3. قمنا بتغيير الاختبار ليتناسب مع التطبيق الجديد
    // (التطبيق الجديد لا يحتوي على عداد "0" أو "1")
    expect(find.text('Hello World!'), findsOneWidget);
  });
}
