#!/bin/bash
echo "🚀 Starting BARINV restore..."
PROJECT_PATH="/Volumes/MiniSSD/IOS BARINV BACKUP/BARINV-PRO IOS"
BACKUP_PATH="/Volumes/MiniSSD/IOS BARINV BACKUP/BARINV-PRO-IOS-v2.2.7"

if [ ! -d "/Volumes/MiniSSD" ]; then
  echo "❌ MiniSSD not mounted."
  exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
  echo "⚠️ Restoring project..."
  cp -R "$BACKUP_PATH" "$PROJECT_PATH"
fi

cd "$PROJECT_PATH" || exit

npm install
npx cap sync ios
rm -rf ~/Library/Developer/Xcode/DerivedData/App-*
npm run build
npm run sync
npx cap open ios

echo "✅ DONE — press Cmd+R in Xcode"
