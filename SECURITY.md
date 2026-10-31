# Security policy

## Reporting

Do not open a public issue containing a working exploit, a WeChat binary, chat
content, credentials, account identifiers or personal data. Use the hosting
platform's private security-advisory channel once the public repository URL is
configured. If no private channel is available, ask the maintainer for a private
contact without including the vulnerability details in the request.

## Scope

Security-sensitive areas include:

- Mach-O load-command injection and entitlement preservation;
- code-page patching and ARM64 trampolines;
- message-object ABI reads and rewrites;
- sandbox and code-signing behavior;
- handling of imported configuration files;
- local logs and exported personal data.

## Coordinated disclosure

Please include the affected build, macOS version, a minimal reproduction and
whether the issue can corrupt data, execute unintended code, leak chat data or
break signatures. Do not publish details until a fix or mitigation is available.
