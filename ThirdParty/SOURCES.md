# Open-source rules used by JSONic

No Python, Presidio runtime, spaCy, PyTorch or model weights are included.

## Red Madrobot pii-guard — Apache-2.0

Copyright 2026 Red Madrobot.
Commit: 24230abb72949a9f85499244dd4f15a0ad0cdd9e
https://github.com/redmadrobot-rnd/pii-guard/tree/24230abb72949a9f85499244dd4f15a0ad0cdd9e

Adapted algorithms:
- src/pii_guard/entities/inn.py — INN-10 / INN-12 control digits.
- src/pii_guard/entities/snils.py — SNILS control number.
- src/pii_guard/entities/passport.py — document format plus explicit passport context (design reference).

Modified in Sources/JSONicCore/StructuredDataDetector.swift on 2026-11-12:
Swift port, precompiled ICU patterns, cancellation, ASCII digits, exclusion of
repeated-digit placeholders, conservative context gating and per-type settings.
Explicit document fields/labels are masked even when the checksum is invalid;
the preview explains this. Checksums are not proof that a document exists.
Unlabelled contiguous numeric identifiers are not classified as INN/SNILS.

The original LICENSE and NOTICE are included. Dependencies listed in the
upstream NOTICE are not bundled in JSONic.

## Microsoft Presidio — MIT

Copyright (c) Microsoft Corporation. All rights reserved.
Commit: aa77b9f98f2c3a2de0f16974e7b540702938707e
https://github.com/microsoft/presidio/blob/aa77b9f98f2c3a2de0f16974e7b540702938707e/presidio-analyzer/presidio_analyzer/predefined_recognizers/generic/email_recognizer.py

EmailRecognizer pattern adapted in StructuredDataDetector.swift:
Unicode/IDN domain labels and plus-addressing; explicit capture boundaries;
no tldextract dependency or network suffix-list download. This is a practical
address detector, not a complete RFC mailbox parser.

The original MIT license is included as presidio-LICENSE.txt.

## JSONic rules

Field aliases and contextual patterns for login, Telegram, credentials and
Russian street/house addresses are implemented locally. IP addresses are
validated and canonicalized with macOS inet_pton / inet_ntop, not inferred
from arbitrary numeric sequences. Telegram handles without field/context and
arbitrary bare usernames are intentionally left unchanged. IP detection is
off by default because server addresses are often needed in technical logs.

Replacement coordinates always refer to the original decoded cell or JSON
string (UTF-16). No global text normalization is applied to the exported data.

## Excel readers

- libxls 1.6.4 — BSD-2-Clause, https://github.com/libxls/libxls/releases/tag/v1.6.4
  Vendored C reader in Vendor/libxls; local config.h/module map for macOS SwiftPM.
  License: libxls-LICENSE.txt.
- ZIPFoundation 0.9.20 — MIT, https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.20
  Vendored Swift sources in Vendor/ZIPFoundation; used to stream XLSX ZIP entries.
  License: ZIPFoundation-LICENSE.txt. OOXML parsing is implemented in JSONic.
