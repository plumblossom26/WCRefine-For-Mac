# Privacy

WCRefine for Mac is local-only software. It does not include telemetry,
analytics, crash upload, remote configuration, advertising, or a network SDK.

## Data the plugin can access

When the corresponding feature is enabled, the injected dylib can read fields
from message objects inside the running WeChat process:

- message type and server message ID;
- sender, recipient and group identifiers;
- message text for the memory-only recall-content cache;
- message timestamps;
- names already visible in the message or entered by the user;
- window sharing state for the screenshot-control feature.

The plugin does not read `contact.db` or message databases directly.

## Memory-only data

Recall text is held in process memory only while content capture is enabled or
needed by the recall-notification workflow. It is capped, replaced by newer
messages and cleared when capture is disabled or the module is uninstalled.
Recent original-ID sessions are also memory-only. They are lost when the
enhanced WeChat process exits.

## Local persistent data

The plugin uses the enhanced copy's own WeChat container for:

- `NSUserDefaults` preferences such as feature toggles, templates, target
  sessions and pet appearance;
- a contact-name cache:
  `Library/Application Support/WCRefine/contact-names.plist`;
- up to eight configuration backups under
  `Library/Application Support/WCRefine/backups/`.

Because the main enhanced copy keeps WeChat's original bundle identifier, it
shares the original WeChat data container. A multi-instance copy changes the
bundle identifier and is intended to receive its own container.

## Exported configuration

The export action writes a plist chosen by the user. It includes keys beginning
with `WCRefineMac`, the learned contact-name cache, the current revision and the
plugin version. Treat the exported file as personal data. It does not include
message bodies.

## Logs and clipboard

The management App may write an installation log under
`~/Library/Logs/WCRefineForMac.log`. The message-repeat module may write
diagnostic state to `~/Library/Logs/WCRefine/message-repeat.log`; those logs do
not contain message bodies. The original-ID feature writes the selected session
ID to the macOS general pasteboard when the user clicks the pet.

## Cleanup

Quit the enhanced copy, then remove its container, logs and any exported plist.
Removing `~/Applications/WCRefine-WeChat.app` does not remove the original
WeChat installation or its data.
