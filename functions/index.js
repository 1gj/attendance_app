/*
 * هذا هو ملف السيرفر (Cloud Functions)
 */

// 1. استيراد المكتبات اللازمة
const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

// تهيئة التطبيق
admin.initializeApp();

// ===================================================================
// الوظيفة الأولى: إرسال تنبيه للمدراء عند تسجيل حضور/انصراف
// ===================================================================
exports.onAttendanceAlert = functions.database
  .ref("/admin_alerts_queue/{pushId}")
  .onWrite(async (snapshot, context) => {
    const alertData = snapshot.after.val();
    if (!alertData) {
      console.log("لا توجد بيانات للحضور.");
      return null;
    }

    const employeeName = alertData.employeeName || "موظف";
    const alertType = alertData.type === "check_in" ? "الحضور" : "الانصراف";
    const title = `تنبيه: ${employeeName}`;
    const body = `قام ${employeeName} بتسجيل ${alertType} الآن.`;

    const payload = {
      notification: {
        title: title,
        body: body,
      },
      data: {
        screen: "EmployeeStatusScreen",
        employeeId: alertData.employeeId || "",
      },
    };

    try {
      await admin.messaging().sendToTopic("admin_alerts", payload);
    } catch (error) {
      console.error("فشل إرسال إشعار الحضور:", error);
    }

    return snapshot.after.ref.remove();
  });

// ===================================================================
// الوظيفة الثانية: إرسال إشعار جماعي من المدير للموظفين
// ===================================================================
exports.onBroadcastNotification = functions.database
  .ref("/notifications_queue/{pushId}")
  .onWrite(async (snapshot, context) => {
    const notificationData = snapshot.after.val();
    if (!notificationData) {
      console.log("لا توجد بيانات للإشعار.");
      return null;
    }

    const payload = {
      notification: {
        title: notificationData.title || "رسالة من الإدارة",
        body: notificationData.body || "رسالة جديدة",
      },
      data: {
        senderName: notificationData.senderName || "Admin",
      },
    };

    try {
      await admin.messaging().sendToTopic("all_employees", payload);
    } catch (error) {
      console.error("فشل إرسال الإشعار الجماعي:", error);
    }

    return snapshot.after.ref.remove();
  });

// ===================================================================
// --- [إضافة جديدة] ---
// الوظيفة الثالثة: معالجة طلبات حذف الموظفين
// ===================================================================
exports.onDeleteUserRequest = functions.database
  // الاستماع للمسار الذي حددناه في التطبيق والقواعد
  .ref("/delete_requests/{pushId}")
  // يتم التشغيل عند إنشاء طلب جديد فقط
  .onCreate(async (snapshot, context) => {
    const requestData = snapshot.val();
    const uidToDelete = requestData.uidToDelete;
    const adminUid = requestData.requestedByAdmin;

    if (!uidToDelete || !adminUid) {
      console.error("طلب حذف غير مكتمل:", requestData);
      return snapshot.ref.remove(); // حذف الطلب الخاطئ
    }

    console.log(`بدء عملية حذف للمستخدم: ${uidToDelete} بناءً على طلب المدير: ${adminUid}`);

    try {
      // 1. حذف حساب المستخدم من (Authentication)
      await admin.auth().deleteUser(uidToDelete);
      console.log(`تم حذف المستخدم ${uidToDelete} من Authentication بنجاح.`);

      // 2. حذف بيانات المستخدم من (Realtime Database)
      await admin.database().ref(`users/${uidToDelete}`).remove();
      console.log(`تم حذف بيانات المستخدم ${uidToDelete} من Database بنجاح.`);

      // (اختياري): يمكنك إضافة كود هنا لحذف سجلات الحضور الخاصة به
      // لكن حذف الحساب وبياناته من /users كافي لإزالته من التطبيق

    } catch (error) {
      console.error(`فشل حذف المستخدم ${uidToDelete}:`, error);
      // يمكنك إرسال إشعار للمدير (adminUid) لإبلاغه بالفشل
    }

    // 3. حذف الطلب من قائمة الانتظار بعد معالجته
    return snapshot.ref.remove();
  });