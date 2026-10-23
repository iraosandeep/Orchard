// Orchard: a local web UI and CLI for Apple's on-device Foundation Model,
// via `fm serve`.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const usage = `Orchard — local UI for Apple's on-device model (via fm serve)

Usage:
  orchard [serve] [-addr 127.0.0.1:1977] [-open] [-no-fm]
                                                   start the web UI (starts and
                                                   keeps fm serve running)
  orchard run <task> [-o option] < input           run a task on stdin
  orchard tasks                                    list tasks

Environment:
  ORCHARD_FM_URL   fm serve base URL (default http://127.0.0.1:1976)
  ORCHARD_HOME     data dir (default ~/.orchard)
`

func main() {
	log.SetFlags(0)
	dir := dataDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		log.Fatal(err)
	}
	fmURL := os.Getenv("ORCHARD_FM_URL")
	if fmURL == "" {
		fmURL = "http://127.0.0.1:1976"
	}
	guard := NewGuard(fmURL)

	args := os.Args[1:]
	cmd := "serve"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve(guard, dir, args)
	case "run":
		err = run(guard, dir, args)
	case "tasks":
		err = listTasks(dir)
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		log.Fatal("orchard: ", err)
	}
}

func dataDir() string {
	if d := os.Getenv("ORCHARD_HOME"); d != "" {
		return d
	}
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatal(err)
	}
	return filepath.Join(home, ".orchard")
}

func serve(guard *Guard, dir string, args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	addr := fs.String("addr", "127.0.0.1:1977", "listen address (loopback only)")
	open := fs.Bool("open", false, "open the UI in the browser")
	noFM := fs.Bool("no-fm", false, "don't start or restart fm serve")
	fs.Parse(args)

	host, _, err := net.SplitHostPort(*addr)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return fmt.Errorf("refusing to bind %s: Orchard is loopback-only", *addr)
	}
	if _, err := LoadTasks(dir); err != nil {
		return err
	}
	store, err := OpenStore(filepath.Join(dir, "orchard.db"))
	if err != nil {
		return err
	}
	srv := &Server{guard: guard, store: store, dir: dir}
	url := "http://" + *addr
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		return err
	}
	log.Printf("Orchard on %s  (fm serve: %s, data: %s)", url, guard.BaseURL, dir)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	fmDone := make(chan struct{})
	if *noFM {
		close(fmDone)
		if !guard.Healthy(ctx) {
			log.Printf("warning: fm serve not reachable — start it with `fm serve`")
		}
	} else {
		go func() { SuperviseFM(ctx, guard, dir); close(fmDone) }()
	}
	if *open {
		exec.Command("open", url).Start()
	}

	hs := &http.Server{Handler: srv.Routes()}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		hs.Shutdown(shutdown)
	}()
	err = hs.Serve(ln)
	<-fmDone // let the supervisor stop any fm serve it started
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}

func run(guard *Guard, dir string, args []string) error {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return fmt.Errorf("usage: orchard run <task> [-o option] < input")
	}
	name, args := args[0], args[1:]
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	opt := fs.String("o", "", "task option (fields, tone, labels…)")
	fs.Parse(args)

	tasks, err := LoadTasks(dir)
	if err != nil {
		return err
	}
	t, ok := FindTask(tasks, name)
	if !ok {
		return fmt.Errorf("no task %q (see `orchard tasks`)", name)
	}
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(in)) == "" {
		return fmt.Errorf("no input on stdin")
	}
	p := t.Prepare(string(in), *opt)
	if started, err := EnsureFM(context.Background(), guard, dir); err != nil {
		return err
	} else if started {
		fmt.Fprintln(os.Stderr, "orchard: started fm serve (left running for next time)")
	}
	if p.Truncated {
		fmt.Fprintf(os.Stderr, "orchard: input truncated to %d of %d chars to fit the model's context\n", p.SentLen, p.InputLen)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	// JSON tasks are buffered so a retry never leaves half-printed output.
	stream := !t.JSON
	out, err := guard.RunTask(ctx, t, p,
		func(d string) error {
			if stream {
				fmt.Print(d)
			}
			return nil
		},
		func() error { fmt.Fprintln(os.Stderr, "orchard: output was not valid JSON, retrying once"); return nil },
	)
	if err != nil {
		return err
	}
	if !stream {
		fmt.Print(out)
	}
	if !strings.HasSuffix(out, "\n") {
		fmt.Println()
	}
	return nil
}

func listTasks(dir string) error {
	tasks, err := LoadTasks(dir)
	if err != nil {
		return err
	}
	for _, t := range tasks {
		extra := ""
		if t.Option != nil {
			extra = fmt.Sprintf("  [-o %s, default %q]", strings.ToLower(t.Option.Label), t.Option.Default)
		}
		fmt.Printf("%-12s %s%s\n", t.Name, t.Label, extra)
	}
	fmt.Printf("\nEdit %s to add or change tasks.\n", filepath.Join(dir, "tasks.yaml"))
	return nil
}
