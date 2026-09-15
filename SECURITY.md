# Security and local operation

Loom is experimental software that can read workspace files, call model providers
and, when authorized, execute commands or write files. It has not received an
independent security audit. Start with non-sensitive workspaces and the default
`ask` approval policy.

## Boundaries to understand

- Desk and service discovery are for the same user on the same machine. Keep
  their listeners on loopback; do not expose them through a proxy, tunnel or
  public interface. They are not a multi-user hosting solution.
- Service descriptors, provider credentials, session history and logs can contain
  sensitive data. Do not commit them or attach them wholesale to a bug report.
- `loom desk --no-open` prints a short-lived, single-use login link. Treat it as
  a credential until consumed or expired. Reopen Desk through the CLI to renew
  browser access; no password is required.
- `--approval auto` broadly approves tools within runtime safeguards. It is not
  an enforced prohibition on publication, destructive actions or provider costs.
- Command sandboxing currently has a macOS Seatbelt backend (`macos-seatbelt`);
  unsupported platforms fail closed. Word automation is a separate desktop
  capability, not proof that arbitrary document parsing is safe.
- Prompts, source excerpts and documents sent to a provider leave your machine
  unless that provider is local. Choose inputs and accounts accordingly.
- Closing a client does not stop service-owned work. Use cancellation, observer
  stop/delete controls or `loom service stop` explicitly. Retained histories and
  worktrees are intentionally not erased by those actions.

## Reporting a vulnerability

Do not post secrets, exploit details against live systems, or private workspace
content in public issues. Use Loom's
[private vulnerability report form](https://github.com/Cozidian/loom/security/advisories/new).
If that channel is unavailable, request a private contact without disclosing the
vulnerability publicly. There is no response-time guarantee.

Include the affected revision, platform, minimal sanitized reproduction, expected
boundary and observed impact. Rotate a credential through its provider if it has
been exposed; deleting a file or commit is not credential revocation.
