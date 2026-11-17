package relay

import "strings"

// routeService maps a public path to the local service that serves it.
//
// LM Studio owns /v1 and /api/v1; the plugin owns the rest of /api; the bridge
// owns its small set of verbs. The MCP port (1237) is intentionally absent:
// LM Studio calls the plugin locally.
func routeService(path string) (string, bool) {
	switch {
	case path == "/v1", strings.HasPrefix(path, "/v1/"):
		return ServiceLMStudio, true
	case path == "/api/v1", strings.HasPrefix(path, "/api/v1/"):
		return ServiceLMStudio, true
	case strings.HasPrefix(path, "/api/"):
		return ServicePlugin, true
	case path == "/health",
		path == "/ps",
		path == "/load",
		path == "/unload",
		path == "/estimate",
		path == "/chat",
		strings.HasPrefix(path, "/chat/"):
		return ServiceBridge, true
	default:
		return "", false
	}
}
