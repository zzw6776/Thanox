./gradlew clean

./gradlew :android_framework:patch-magisk:bridge-dex-app:extractBridgeJar --no-daemon
./gradlew :android_framework:patch-magisk:module:zipRelease --no-daemon

./gradlew app:assemblePrcRelease --no-daemon
