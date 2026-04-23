import { PushNotifications } from '@capacitor/push-notifications';

let pushToken: string | null = null;

export async function initPushNotifications(): Promise<string | null> {
  const permResult = await PushNotifications.requestPermissions();
  if (permResult.receive !== 'granted') {
    console.warn('[BARINV] Push notification permission denied');
    return null;
  }

  await PushNotifications.register();

  return new Promise((resolve) => {
    PushNotifications.addListener('registration', (token) => {
      pushToken = token.value;
      console.log('[BARINV] Push token:', token.value);
      resolve(token.value);
    });

    PushNotifications.addListener('registrationError', (error) => {
      console.error('[BARINV] Push registration error:', error);
      resolve(null);
    });

    PushNotifications.addListener('pushNotificationReceived', (notification) => {
      window.dispatchEvent(new CustomEvent('push-notification', {
        detail: {
          title: notification.title,
          body: notification.body,
          data: notification.data
        }
      }));
    });

    PushNotifications.addListener('pushNotificationActionPerformed', (action) => {
      const data = action.notification.data;
      if (data?.page) {
        window.dispatchEvent(new CustomEvent('push-navigate', { detail: { page: data.page } }));
      }
    });
  });
}

export function getToken(): string | null {
  return pushToken;
}
