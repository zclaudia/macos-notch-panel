# IslandKit

Build and check on macOS 14 or later with Swift 5.9 or later:

```sh
cd IslandKit
swift build
swift test
swift run island-check
```

Run boringNotch and approve the `island` executable on first use. Activities belong
to the approved program identity and resolved executable path, so separate CLI
invocations can update or end the same activity. Disconnecting does not dismiss
activities: `present` expires after its duration; `start` remains until ended,
dismissed, its optional expiration, or the panel exits. Use unique IDs for
independent jobs. State is kept in memory and is cleared when the panel exits.

```sh
.build/debug/island present --id notice --title "Build finished" --duration 10
.build/debug/island start --id build --title "Building" --progress 0
.build/debug/island update --id build --title "Almost done" --progress 0.9
.build/debug/island end --id build
```

For a panel integration check, verify that `notice` remains visible after the CLI
exits and expires after ten seconds. Then run the `start`, `update`, and `end`
commands separately and verify that they update and dismiss the same activity.
An executable at a different path must not be able to update or end it.
With the panel running, `swift run island-check --live` also checks CLI
start/update/end across processes and verifies that a presentation survives
disconnecting and retains its expiration after an update. Approve `island` if
prompted by the panel.

SDK event callbacks run serially on a separate queue and may call `update` or
`end` synchronously. Events are delivered to active connections of the owning
program; they are not replayed after reconnecting. A CLI invocation exits after
its response, so receive callbacks through a long-lived SDK connection.

Server output is ordered on a background queue, limited to 64 pending messages
per connection, with a two-second socket send timeout. A slow or disconnected
peer is shut down without waiting on the UI thread.
