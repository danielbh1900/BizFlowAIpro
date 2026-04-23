import { BleClient } from '@capacitor-community/bluetooth-le';

// Escali SmartConnect SC115KS — Chipsea chipset
// Service: FFF0, Command: FFF1 (write), Weight Data: FFF4 (notify)
const SCALE_SVC  = '0000fff0-0000-1000-8000-00805f9b34fb';
const SCALE_CMD  = '0000fff1-0000-1000-8000-00805f9b34fb';
const SCALE_DATA = '0000fff4-0000-1000-8000-00805f9b34fb';

let connectedDeviceId: string | null = null;
let activeServiceUuid: string | null = null;
let activeCharUuid: string | null = null;

export async function initBLE(): Promise<void> {
  await BleClient.initialize({ androidNeverForLocation: true });
}

export async function scanForScale(): Promise<string | null> {
  return new Promise((resolve) => {
    let found = false;
    const candidates: { id: string; rssi: number }[] = [];

    BleClient.requestLEScan({}, (result) => {
      if (found) return;
      const name = (result.device.name || result.localName || '').toLowerCase();
      const uuids = (result.uuids || []).map(u => u.toLowerCase());

      // Best: advertises FFF0 service
      if (uuids.some(u => u.includes('fff0'))) {
        found = true;
        BleClient.stopLEScan();
        resolve(result.device.deviceId);
        return;
      }

      // Good: name match
      if (name.includes('escali') || name.includes('smartconnect') || name.includes('sc115') || name.includes('chipsea')) {
        found = true;
        BleClient.stopLEScan();
        resolve(result.device.deviceId);
        return;
      }

      // Candidate: strong signal with services
      if (result.rssi && result.rssi > -65 && uuids.length > 0) {
        candidates.push({ id: result.device.deviceId, rssi: result.rssi });
      }
    });

    setTimeout(() => {
      if (!found) {
        BleClient.stopLEScan();
        const best = candidates.sort((a, b) => b.rssi - a.rssi)[0];
        resolve(best?.id || null);
      }
    }, 12000);
  });
}

export async function connectScale(deviceId: string): Promise<{ serviceUuid: string; charUuid: string }> {
  await BleClient.connect(deviceId, () => {
    connectedDeviceId = null;
    window.dispatchEvent(new CustomEvent('ble-disconnected'));
  });
  connectedDeviceId = deviceId;

  // Try Chipsea FFF0/FFF4 protocol first
  try {
    await BleClient.startNotifications(deviceId, SCALE_SVC, SCALE_DATA, (value) => {
      const weight = parseWeight(value);
      if (weight !== null) {
        window.dispatchEvent(new CustomEvent('ble-weight', { detail: { weight } }));
      }
    });
    activeServiceUuid = SCALE_SVC;
    activeCharUuid = SCALE_DATA;
    return { serviceUuid: SCALE_SVC, charUuid: SCALE_DATA };
  } catch {
    // Fallback: discover services
  }

  const services = await BleClient.getServices(deviceId);
  for (const service of services) {
    const svcShort = service.uuid.substring(4, 8).toLowerCase();
    if (['1800', '1801', '180a'].includes(svcShort)) continue;

    for (const char of service.characteristics) {
      if (char.properties.notify || char.properties.indicate) {
        await BleClient.startNotifications(deviceId, service.uuid, char.uuid, (value) => {
          const weight = parseWeight(value);
          if (weight !== null) {
            window.dispatchEvent(new CustomEvent('ble-weight', { detail: { weight } }));
          }
        });
        activeServiceUuid = service.uuid;
        activeCharUuid = char.uuid;
        return { serviceUuid: service.uuid, charUuid: char.uuid };
      }
    }
  }
  throw new Error('No weight characteristic found');
}

export async function disconnectScale(): Promise<void> {
  if (connectedDeviceId) {
    if (activeServiceUuid && activeCharUuid) {
      try { await BleClient.stopNotifications(connectedDeviceId, activeServiceUuid, activeCharUuid); } catch { /* */ }
    }
    try { await BleClient.disconnect(connectedDeviceId); } catch { /* */ }
    connectedDeviceId = null;
    activeServiceUuid = null;
    activeCharUuid = null;
  }
}

export function isConnected(): boolean {
  return connectedDeviceId !== null;
}

function parseWeight(dataView: DataView): number | null {
  try {
    const len = dataView.byteLength;
    if (len >= 2) { const w = dataView.getInt16(0, true); if (w >= 0 && w <= 5500) return w; }
    if (len >= 3) { const w = dataView.getInt16(1, true); if (w >= 0 && w <= 5500) return w; }
    if (len >= 2 && len <= 12) {
      const bytes = new Uint8Array(dataView.buffer, dataView.byteOffset, len);
      const str = String.fromCharCode(...bytes).trim();
      const match = str.match(/(\d+(\.\d+)?)/);
      if (match) { const w = parseFloat(match[1]); if (w >= 0 && w <= 5500) return Math.round(w); }
    }
    return null;
  } catch { return null; }
}
