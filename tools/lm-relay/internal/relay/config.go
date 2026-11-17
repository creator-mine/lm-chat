// Package relay implements the public side of the tunnel: it authenticates
// clients, routes requests to a device and multiplexes them into the agent's
// WebSocket connection.
package relay

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"time"

	"github.com/Spe4naz/lm-chat/tools/lm-relay/internal/protocol"
)

// Service names used by the agent and by the route table.
const (
	ServiceLMStudio = protocol.ServiceLMStudio
	ServiceBridge   = protocol.ServiceBridge
	ServicePlugin   = protocol.ServicePlugin
)

var knownServices = []string{
	ServiceLMStudio,
	ServiceBridge,
	ServicePlugin,
	protocol.ServiceE2E,
}

// Device is one LM Studio machine allowed to attach to this relay.
type Device struct {
	// AgentSecret authenticates the outbound WebSocket from the agent.
	AgentSecret string `json:"agent_secret"`
	// AccessToken authenticates the app's HTTP requests to this device.
	AccessToken string `json:"access_token"`
	// Services limits which local services the device exposes. Empty means
	// all three.
	Services []string `json:"services,omitempty"`
}

func (d Device) allows(service string) bool {
	if service == protocol.ServiceE2E {
		return true
	}
	if len(d.Services) == 0 {
		return true
	}
	return slices.Contains(d.Services, service)
}

// Config is the relay configuration file.
type Config struct {
	Listen          string            `json:"listen"`
	MaxBodyBytes    int64             `json:"max_body_bytes"`
	ResponseTimeout string            `json:"response_timeout"`
	MaxStreams      int               `json:"max_streams"`
	RatePerSecond   float64           `json:"rate_per_second"`
	RateBurst       float64           `json:"rate_burst"`
	Devices         map[string]Device `json:"devices"`
}

// LoadConfig reads, defaults and validates a relay configuration.
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
	if c.Listen == "" {
		c.Listen = "127.0.0.1:8787"
	}
	if c.MaxBodyBytes <= 0 {
		c.MaxBodyBytes = 16 << 20
	}
	if c.ResponseTimeout == "" {
		c.ResponseTimeout = "5m"
	}
	if c.MaxStreams <= 0 {
		c.MaxStreams = 64
	}
	if c.RatePerSecond <= 0 {
		c.RatePerSecond = 20
	}
	if c.RateBurst <= 0 {
		c.RateBurst = 40
	}
}

func (c Config) validate() error {
	if len(c.Devices) == 0 {
		return fmt.Errorf("relay: no devices configured")
	}
	if _, err := c.ResponseDuration(); err != nil {
		return err
	}
	for id, dev := range c.Devices {
		if id == "" {
			return fmt.Errorf("relay: empty device id")
		}
		if len(dev.AgentSecret) < 16 {
			return fmt.Errorf("relay: device %q agent_secret must be at least 16 bytes", id)
		}
		if len(dev.AccessToken) < 16 {
			return fmt.Errorf("relay: device %q access_token must be at least 16 bytes", id)
		}
		for _, service := range dev.Services {
			if !slices.Contains(knownServices, service) {
				return fmt.Errorf("relay: device %q has unknown service %q", id, service)
			}
		}
	}
	return nil
}

// ResponseDuration is the parsed response timeout.
func (c Config) ResponseDuration() (time.Duration, error) {
	d, err := time.ParseDuration(c.ResponseTimeout)
	if err != nil {
		return 0, fmt.Errorf("relay: response_timeout: %w", err)
	}
	if d <= 0 {
		return 0, fmt.Errorf("relay: response_timeout must be positive")
	}
	return d, nil
}
