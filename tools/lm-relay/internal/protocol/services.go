package protocol

// Local services the agent can proxy to. The names are part of the wire
// protocol and must match the route table on the relay.
const (
	ServiceLMStudio = "lmstudio"
	ServiceBridge   = "bridge"
	ServicePlugin   = "plugin"
	// ServiceE2E is the opaque transport used for end-to-end encryption.
	ServiceE2E = "e2e"
)
