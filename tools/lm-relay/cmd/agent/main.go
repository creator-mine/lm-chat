package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/creator-mine/lm-chat/tools/lm-relay/internal/agent"
)

func main() {
	configPath := flag.String("config", "agent.json", "path to the agent configuration")
	logLevel := flag.String("log-level", "info", "log level: debug, info, warn or error")
	printIdentity := flag.Bool("print-identity", false, "print the E2E public key and fingerprint, then exit")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: parseLevel(*logLevel),
	}))

	cfg, err := agent.LoadConfig(*configPath)
	if err != nil {
		logger.Error("configuration error", "error", err)
		os.Exit(1)
	}
	runner, err := agent.New(cfg, logger)
	if err != nil {
		logger.Error("agent error", "error", err)
		os.Exit(1)
	}
	if *printIdentity {
		fmt.Printf("public_key: %s\n", runner.PublicKey())
		fmt.Printf("fingerprint: %s\n", runner.Fingerprint())
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := runner.Run(ctx); err != nil {
		logger.Error("agent stopped", "error", err)
		os.Exit(1)
	}
}

func parseLevel(value string) slog.Level {
	switch value {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
