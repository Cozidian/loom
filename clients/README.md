# BeamAgent clients

Start both loopback interfaces for a durable goal:

```sh
./beam_agent serve SESSION_ID
```

The command prints the browser URL and JSON-lines address. The generated token
is embedded in the browser URL; copy the same token, host, and port into the
VS Code or Emacs client settings. Both clients speak protocol version 1 and
only observe/control the Elixir runtime—they own no goal or conversation state.

- `vscode/extension.js` is a dependency-free VS Code extension entrypoint.
- `emacs/beam-agent.el` provides connect, status, submit, and cancel commands.

The external protocol supports snapshot/status/tree/budget/model/repository,
resource/delegation/organization/worktree/context inspection, submission,
cancellation, verification, approvals, and project routing preferences. Live
goal events arrive as separate `type: "event"` JSON lines.
