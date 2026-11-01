# Cryptomator dependency licensing

The vendored official cryptolib-swift is pinned in upstream.json and is dual licensed: AGPLv3 for FOSS projects, or a separate commercial license offered by Skymatic for applications not licensed under AGPL. No commercial license is implied or bundled here. The current build is for the owner's local testing, with corresponding project and dependency source delivered together; it has not been publicly published or submitted to an App Store.

Before redistribution, choose an AGPL-compatible license for the combined application and provide corresponding source/build instructions/notices as required, or obtain the appropriate commercial license. This file does not unilaterally relicense the owner's application code. The same decision applies to a future iOS/iPadOS product; do not assume the open-source license is automatically compatible with the intended distribution terms.

Recovery wordlist: copied from the pinned official Cryptomator desktop source; its GPLv3 license is preserved in CRYPTOMATOR-DESKTOP-LICENSE.txt. The official cryptolib copyright and AGPL text remain in CryptomatorCryptoLib/. scrypt's own notices remain in its source files. Existing rclone dependency notices remain in Resources/THIRD_PARTY_NOTICES.txt and Engine/.

Cryptolib source is unmodified. Optional research-only Base32, Java/JDK and Cryptomator desktop checkout outside this source directory are not application dependencies and are not shipped. Java interop test requires an independently installed Cryptomator and Java 25+, neither is bundled in CloudMount.
