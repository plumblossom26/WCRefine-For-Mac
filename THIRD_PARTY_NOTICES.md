# Third-party notices

## WeChat / Tencent

WCRefine is an independent project. It is not affiliated with Tencent or the
WeChat team. The repository does not contain or redistribute the WeChat
application, `wechat.dylib`, Tencent private keys, account data or decryption
material. "WeChat" and "微信" are used only to identify the host application
whose local copy the user chooses to modify.

Installing WCRefine may be inconsistent with the host application's terms.
Users are responsible for deciding whether to install it.

## Apple frameworks

The source imports system frameworks and headers supplied by the macOS SDK,
including Foundation, AppKit, WebKit, CommonCrypto and Mach interfaces. These
frameworks are not redistributed by this repository.

## Floating pet

`Resources/kimi-pet/index.html` is project code. It mounts the local pet and
applies the hue slider. It does not load remote scripts, images or fonts.

`Resources/kimi-pet/pet.js` is the Kimi desktop pet. The file bundles Three.js,
which is MIT licensed:

```
Copyright 2010-2026 Three.js Authors
SPDX-License-Identifier: MIT
```

The bundle is shipped inside the app resources and is not fetched at runtime.

## Python helper

`Tools/macho_inject.py` is project code and is covered by the repository MIT
license. It uses only the Python standard library.

## No plugin dependency

The built dylib links only Apple system frameworks and libraries. It does not
link Substrate, Substitute, ElleKit, Frida, Cephei, PreferenceLoader, Logos,
fishhook, or another third-party plugin runtime.
