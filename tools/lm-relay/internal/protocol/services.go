package protocol

// Local services the agent can proxy to. The names are part of the wire
// protocol and must match the route table on the relay.
const (
	ServiceLMStudio = "lmstudio"
	ServiceBridge   = "bridge"
	ServicePlugin   = "plugin"
)
