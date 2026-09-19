# Embed GnosticCore as a consumer-only Gnostic client

Yakamoz gains a Gnostic client mode by linking `GnosticCore` and Axoloty inside a dedicated
`YakamozNetwork` module, and acting strictly as a consumer: it discovers advertised objects
and runs Turns, but never hosts a Node or advertises one. The cost is shared with Gnostic:
the same PositronicKit line and macOS deployment baseline. The benefit is one coherent
client — discovery and interaction over the real wire contract — instead of bridging two
partial surfaces.

## Considered options

- **`gnostic` CLI subprocess (`gnostic inspect` + `gnostic acp`)**: rejected — ACP carries
  no discovery and no attach or tool invocation, so two mechanisms could never form one
  client, and discovery would be snapshot-only.
- **Upstream-only client artifact**: rejected for Yakamoz v1 — a public Gnostic client
  library is pursued upstream in parallel, but waiting for it would stall the app feature;
  Yakamoz embeds the public primitives today and adopts the facade when it lands.
- **ACP-only**: rejected — sessions without discovery are not "use Gnostic"; browsing the
  network is the point.

## Consequences

Consumer-only is a current scope decision, not a structural limit: a later presence feature
may advertise the client without changing this boundary. Because discovery is live
(advertise/deadvertise observation), network entries are presentation state, not persisted
identity; only a thin reconnect reference is stored locally.
