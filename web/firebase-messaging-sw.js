// firebase-messaging-sw.js

importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

// Initialize Firebase
firebase.initializeApp({
  apiKey: "AIzaSyD4P3d4S1ZrhfBy9w4YqSP6i6u5b7fX4x0",
  authDomain: "allowance-001.firebaseapp.com",
  projectId: "allowance-001",
  storageBucket: "allowance-001.appspot.com",
  messagingSenderId: "463313212619",
  appId: "1:463313212619:web:be9b0c2f1a76d5f8e2f3e7"
});

const messaging = firebase.messaging();

// Handle background messages
messaging.onBackgroundMessage((payload) => {
  console.log('[firebase-messaging-sw.js] Received background message:', payload);

  const notificationTitle = payload.notification?.title || 'Allowance';
  const notificationOptions = {
    body: payload.notification?.body || '',
    icon: '/icons/Icon-192.png',   // Make sure this file exists in build/web/icons/
    badge: '/icons/Icon-192.png',
    data: payload.data || {},
    tag: payload.notification?.tag || 'allowance-notification',
  };

  self.registration.showNotification(notificationTitle, notificationOptions);
});
