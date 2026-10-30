# Google Maps setup for Nereus Android

Google Maps rendering is not enabled in this build. The layer picker labels it as requiring setup. OpenSeaMap and NOAA continue to work without a Google key.

1. Create or choose a Google Cloud project, associate a billing account, and enable **Maps SDK for Android**.
2. Create an API key. Under application restrictions choose **Android apps**, with package name `com.nereus.anchorwatch` and your signing certificate SHA-1. Under API restrictions allow **Maps SDK for Android** only.
3. Obtain the debug SHA-1 in Android Studio's Gradle signing report, or run `./gradlew :app:signingReport` from this directory. Release signing will require its own fingerprint later.
4. Store the key only in the ignored `android/local.properties` as `GOOGLE_MAPS_API_KEY=your_key`. Do not paste it into chat or commit it.
5. Once configured, the Google Maps SDK renderer can be connected and tested with the same boat, anchor, track, tether and hazard interactions. A key alone does not activate Google Maps in this build.

Google's official setup guide: https://developers.google.com/maps/documentation/android-sdk/get-api-key
Billing setup: https://developers.google.com/maps/get-started

Do not use unofficial Google tile URLs in MapLibre. Google Maps must be integrated through a supported Google Maps SDK with its attribution and usage requirements.
