import { Camera, CameraResultType, CameraSource } from '@capacitor/camera';
import { CapacitorBarcodeScanner, CapacitorBarcodeScannerTypeHintALLOption } from '@capacitor/barcode-scanner';

export async function takePhoto(): Promise<string | null> {
  const image = await Camera.getPhoto({
    quality: 80,
    allowEditing: false,
    resultType: CameraResultType.Base64,
    source: CameraSource.Camera,
    width: 1200,
    correctOrientation: true
  });
  return image.base64String ? `data:image/${image.format};base64,${image.base64String}` : null;
}

export async function pickFromGallery(): Promise<string | null> {
  const image = await Camera.getPhoto({
    quality: 80,
    allowEditing: false,
    resultType: CameraResultType.Base64,
    source: CameraSource.Photos,
    width: 1200,
    correctOrientation: true
  });
  return image.base64String ? `data:image/${image.format};base64,${image.base64String}` : null;
}

export async function scanBarcode(): Promise<string | null> {
  const result = await CapacitorBarcodeScanner.scanBarcode({
    hint: CapacitorBarcodeScannerTypeHintALLOption.ALL
  });
  return result.ScanResult || null;
}
