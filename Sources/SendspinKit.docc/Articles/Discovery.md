# Discovery and Connection

Find Sendspin servers on the local network or let servers find you.

## Overview

The Sendspin protocol supports two connection patterns. In **client-initiated** mode, the client discovers servers via mDNS and opens a WebSocket connection. In **server-initiated** mode, the client advertises itself and accepts incoming connections from servers.

Both patterns use Bonjour/mDNS service types defined in ``SendspinDefaults``.

## Client-initiated discovery

``ServerDiscovery`` uses the Network framework to browse for `_sendspin-server._tcp` services:

```swift
let discovery = ServerDiscovery()
try await discovery.startDiscovery()

// servers is an AsyncStream that emits the current set of discovered servers
// whenever a server appears or disappears
for await servers in discovery.servers {
    for server in servers {
        print("\(server.name) at \(server.url)")
    }
}
```

Each ``DiscoveredServer`` provides a resolved URL ready for ``SendspinClient/connect(to:)``.

When you're done discovering, stop the browser:

```swift
await discovery.stopDiscovery()
```

## Server-initiated connections

The client owns Bonjour advertising, incoming handshakes, and connection arbitration:

```swift
try await client.startAdvertising(port: SendspinDefaults.clientPort)
// Returns when the listener is ready, not when a server has connected.
```

Observe `client.listenerState` independently from `client.connectionState`. Outgoing connections
and advertising are mutually exclusive; stop the listener and disconnect admitted sessions
before switching modes. `ClientAdvertiser` and `acceptConnection(_:)` remain advanced transport hooks.

## Lifecycle

`client.stopAdvertising()` stops new candidates but retains admitted sessions. A subsequent
`startAdvertising()` creates a fresh listener. `client.disconnect()` retires sessions without
stopping an active listener; `client.close()` permanently stops both and finishes the client streams.

The lower-level ``ServerDiscovery`` and ``ClientAdvertiser`` actors remain one-shot: create a new
instance after stopping them.
