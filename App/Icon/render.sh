#!/bin/sh
# Renders AppIcon.svg into every macOS app icon size (needs rsvg-convert: brew install librsvg).
set -e
cd "$(dirname "$0")"
out=../Assets.xcassets/AppIcon.appiconset
mkdir -p "$out"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size AppIcon.svg -o "$out/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) AppIcon.svg -o "$out/icon_${size}x${size}@2x.png"
done
cat > "$out/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > ../Assets.xcassets/Contents.json <<JSON
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "wrote $out"
