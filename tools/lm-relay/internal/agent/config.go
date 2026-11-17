package agent

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"slices"
	"strings"
)

// Config is the agent configuration file.
type Config struct {
	// RelayURL is the public WebSocket endpoint, e.g.
	// wss://lm.example.com/_tunnel.
	RelayURL string `json:"relay_url"`
	// DeviceID selects the device entry on the relay.
	DeviceID string `json:"device_id"`
	// AgentSecret is the relay-side secret for this device.
	AgentSecret string `json:"agent_secret"`
	// Services maps a service name to a local base URL.
	Services map[string]string `json:"services"`
	// CAFile optionally pins a private CA for a self-signed relay.
	CAFile string `json:"ca_file,omitempty"`
	// AllowShutdown lets remote clients call POST /api/shutdown. It is off by
	// default because the plugin would then stay down until someone touches
	// the machine.
	AllowShutdown bool `json:"allow_shutdown"`
	// IdentityFile is the agent's X25519 key. It is created on first start.
	IdentityFile string `json:"identity_file,omitempty"`
}

var defaultServices = map[string]string{
	"lmstudio": "http://127.0.0.1:1234",
	"bridge":   "http://127.0.0.1:1235",
	"plugin":   "http://127.0.0.1:1236",
}

// LoadConfig reads, defaults and validates an agent configuration.
func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parse %s: %w", path, err)
	}
	cfg.applyDefaults()
	if err := cfg.validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c *Config) applyDefaults() {
	if c.Services == nil {
		c.Services = make(map[string]string, len(defaultServices))
	}
	for name, address := range defaultServices {
		if _, ok := c.Services[name]; !ok {
			c.Services[name] = address
		}
	}
}

func (c Config) validate() error {
	u, err := url.Parse(c.RelayURL)
	if err != nil {
		return fmt.Errorf("agent: relay_url: %w", err)
	}
	if u.Scheme != "ws" && u.Scheme != "wss" {
		return fmt.Errorf("agent: relay_url must use ws:// or wss://")
	}
	if u.Host == "" {
		return fmt.Errorf("agent: relay_url has no host")
	}
	if strings.TrimSpace(c.DeviceID) == "" {
		return fmt.Errorf("agent: device_id is empty")
	}
	if len(c.AgentSecret) < 16 {
		return fmt.Errorf("agent: agent_secret must be at least 16 bytes")
	}
	if len(c.Services) == 0 {
		return fmt.Errorf("agent: no services configured")
	}
	for name, address := range c.Services {
		if !slices.Contains([]string{"lmstudio", "bridge", "plugin"}, name) {
			return fmt.Errorf("agent: unknown service %q", name)
		}
		target, err := url.Parse(address)
		if err != nil {
			return fmt.Errorf("agent: service %q: %w", name, err)
		}
		if target.Scheme != "http" && target.Scheme != "https" {
			return fmt.Errorf("agent: service %q must use http:// or https://", name)
		}
		if target.Host == "" {
			return fmt.Errorf("agent: service %q has no host", name)
		}
	}
	return nil
}
