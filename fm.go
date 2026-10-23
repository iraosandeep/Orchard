package main

// Starting and supervising `fm serve`, so Orchard works without a separate
// terminal and recovers if fm serve dies.

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

func (g *Guard) Healthy(ctx context.Context) bool {
	_, err := g.Health(ctx)
	return err == nil
}

// startFM launches `fm serve` on the guard's port, logging to dir/fm.log, and
// waits until it answers /health. The process gets its own session so it
// survives the caller (useful for `orchard run` from git hooks).
func startFM(ctx context.Context, g *Guard, dir string) (*exec.Cmd, error) {
	u, err := url.Parse(g.BaseURL)
	if err != nil {
		return nil, err
	}
	if ip := net.ParseIP(u.Hostname()); u.Hostname() != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return nil, fmt.Errorf("not starting fm serve: %s is not loopback", g.BaseURL)
	}
	fm, err := exec.LookPath("fm")
	if err != nil {
		return nil, fmt.Errorf("fm not found on PATH (needs macOS 26+ with Apple Intelligence)")
	}
	port := u.Port()
	if port == "" {
		port = "80"
	}
	logf, err := os.OpenFile(filepath.Join(dir, "fm.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	defer logf.Close()
	cmd := exec.Command(fm, "serve", "--port", port)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()

	deadline := time.After(15 * time.Second)
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case err := <-exited:
			return nil, fmt.Errorf("fm serve exited at startup (%v); see %s", err, filepath.Join(dir, "fm.log"))
		case <-deadline:
			cmd.Process.Kill()
			return nil, fmt.Errorf("fm serve did not become healthy within 15s")
		case <-ctx.Done():
			cmd.Process.Kill()
			return nil, ctx.Err()
		case <-tick.C:
			if g.Healthy(ctx) {
				return cmd, nil
			}
		}
	}
}

// EnsureFM starts fm serve if it isn't reachable. The started process is
// left running.
func EnsureFM(ctx context.Context, g *Guard, dir string) (started bool, err error) {
	if g.Healthy(ctx) {
		return false, nil
	}
	cmd, err := startFM(ctx, g, dir)
	if err != nil {
		return false, err
	}
	cmd.Process.Release()
	return true, nil
}

// SuperviseFM keeps fm serve up while ctx is alive: it checks health every
// few seconds and restarts fm serve after two failed checks in a row. Any
// fm serve this supervisor started is stopped when ctx ends.
func SuperviseFM(ctx context.Context, g *Guard, dir string) {
	var owned *exec.Cmd
	defer func() {
		if owned != nil {
			owned.Process.Signal(syscall.SIGTERM)
		}
	}()
	failures := 0
	check := func() {
		if g.Healthy(ctx) {
			failures = 0
			return
		}
		if failures++; failures < 2 && owned != nil {
			return
		}
		if owned != nil {
			owned.Process.Kill()
			owned = nil
		}
		cmd, err := startFM(ctx, g, dir)
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("fm serve: %v (will retry)", err)
			}
			return
		}
		log.Printf("fm serve started (pid %d)", cmd.Process.Pid)
		owned, failures = cmd, 0
	}
	check()
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			check()
		}
	}
}
