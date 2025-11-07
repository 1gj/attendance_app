/*
 * هذا هو ملف السيرفر (Cloud Functions)
 * وظيفته الاستماع للتغييرات في قاعدة البيانات وإرسال الإشعارات
 */

// 1. استيراد المكتبات اللازمة
// (نستخدم v1 لأننا قمنا بتثبيت إصدارات محددة)
const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

// تهيئة التطبيق (ليعرف السيرفر أي مشروع يتبع)
admin.initializeApp();

// ===================================================================
// الوظيفة الأولى: إرسال تنبيه للمدراء عند تسجيل حضور/انصراف
// ===================================================================
exports.onAttendanceAlert = functions.database
  // المسار الذي تستمع له الوظيفة (نفس المسار الذي كتبناه في التطبيق)
  .ref("/admin_alerts_queue/{pushId}")
  // الحدث: "onWrite" (يتم تشغيله عند إنشاء بيانات جديدة)
  .onWrite(async (snapshot, context) => {
    // جلب البيانات التي أرسلها الموظف (مثل: اسم الموظف، الوقت)
    const alertData = snapshot.after.val();
    if (!alertData) {
      console.log("لا توجد بيانات للحضور.");
      return null;
    }

    // تجهيز رسالة الإشعار
    const employeeName = alertData.employeeName || "موظف";
    const alertType = alertData.type === "check_in" ? "الحضور" : "الانصراف";
    const title = `تنبيه: ${employeeName}`;
    const body = `قام ${employeeName} بتسجيل ${alertType} الآن.`;

    // 2. تجهيز حمولة الإشعار (Payload)
    const payload = {
      notification: {
        title: title,
        body: body,
      },
      // بيانات إضافية (اختياري)
      data: {
        screen: "EmployeeStatusScreen", // لتوجيه المدير للشاشة الصحيحة
        employeeId: alertData.employeeId || "",
      },
    };

    // 3. إرسال الإشعار إلى "الموضوع" الذي يشترك فيه المدراء
    try {
      await admin
        .messaging()
        .sendToTopic("admin_alerts", payload); // هذا هو اسم الـ Topic للمدراء
    } catch (error) {
      console.error("فشل إرسال إشعار الحضور:", error);
    }

    // 4. (مهم) حذف السجل من قائمة الانتظار بعد معالجته
    return snapshot.after.ref.remove();
  });

// ===================================================================
// الوظيفة الثانية: إرسال إشعار جماعي من المدير للموظفين
// ===================================================================
exports.onBroadcastNotification = functions.database
  // المسار الذي يستمع له (نفس المسار الذي كتبناه في شاشة المدير)
  .ref("/notifications_queue/{pushId}")
  .onWrite(async (snapshot, context) => {
    // جلب بيانات الرسالة (العنوان والنص)
    const notificationData = snapshot.after.val();
    if (!notificationData) {
      console.log("لا توجد بيانات للإشعار.");
      return null;
    }

    // 1. تجهيز حمولة الإشعار (Payload)
    const payload = {
      notification: {
        title: notificationData.title || "رسالة من الإدارة",
        body: notificationData.body || "رسالة جديدة",
      },
      data: {
        senderName: notificationData.senderName || "Admin",
      },
    };

    // 2. إرسال الإشعار إلى "الموضوع" الذي يشترك فيه جميع الموظفين
    try {
      await admin
        .messaging()
        .sendToTopic("all_employees", payload); // هذا هو اسم الـ Topic للموظفين
    } catch (error) {
      console.error("فشل إرسال الإشعار الجماعي:", error);
    }

    // 3. (مهم) حذف السجل من قائمة الانتظار بعد معالجته
    return snapshot.after.ref.remove();
  });