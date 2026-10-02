package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nkuhn-vmw/cfctx/internal/run"
)

var version = "dev"

func main() { os.Exit(mainRun()) }
func mainRun() int {
	if len(os.Args) == 2 && (os.Args[1] == "--version" || os.Args[1] == "version") {
		fmt.Println("cfctx-run", version)
		return 0
	}
	flags := flag.NewFlagSet("cfctx-run", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	provider := flags.String("provider", "", "portal or mcp")
	workspace := flags.String("workspace", "", "workspace handle")
	foundation := flags.String("foundation", "", "foundation name")
	capability := flags.String("capability", "", "capability name")
	descriptor := flags.String("descriptor", "", "reviewed non-secret descriptor file")
	requestFD := flags.Int("request-fd", -1, "read a v1 request from file descriptor 3")
	contract := flags.Bool("contract", false, "print supported execution contract")
	if flags.Parse(os.Args[1:]) != nil {
		return 2
	}
	requestFDSet := false
	flags.Visit(func(f *flag.Flag) {
		if f.Name == "request-fd" {
			requestFDSet = true
		}
	})
	if *contract {
		if flags.NArg() != 0 || requestFDSet || *provider != "" || *workspace != "" || *foundation != "" || *capability != "" || *descriptor != "" {
			fmt.Fprintln(os.Stderr, "cfctx-run: --contract cannot be combined with execution options")
			return 2
		}
		fmt.Println(run.ContractJSON)
		return 0
	}
	requestMode := requestFDSet
	if requestMode {
		if *requestFD != 3 || *provider != "" || *workspace != "" || *foundation != "" || *capability != "" || *descriptor != "" || flags.NArg() < 1 {
			fmt.Fprintln(os.Stderr, "cfctx-run: invalid request command line")
			return 2
		}
		return runRequest(flags.Args())
	}
	selection := run.Selection{Workspace: *workspace, Foundation: *foundation, Capability: *capability}
	d, err := run.LoadDescriptor(*descriptor)
	if err != nil || d.Validate(selection) != nil || len(flags.Args()) == 0 {
		fmt.Fprintln(os.Stderr, "cfctx-run: invalid workspace descriptor, selection or command")
		return 2
	}
	var source run.Provider
	switch *provider {
	case "portal":
		source = run.Portal{Context: d.PortalContext}
	case "mcp":
		source = run.MCP{Endpoint: d.MCPEndpoint}
	default:
		fmt.Fprintln(os.Stderr, "cfctx-run: choose --provider portal or mcp")
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
	defer stop()
	lookup, cancel := context.WithTimeout(ctx, 30*time.Second)
	profile, err := source.Resolve(lookup, selection)
	cancel()
	if err != nil {
		if ctx.Err() != nil {
			return 130
		}
		fmt.Fprintln(os.Stderr, "cfctx-run: workspace credential retrieval failed; check provider authorization and configuration")
		return 1
	}
	code, err := run.Execute(ctx, profile, d, selection, flags.Args(), os.Stdin, os.Stdout, os.Stderr)
	if err != nil {
		if ctx.Err() != nil {
			return 130
		}
		fmt.Fprintln(os.Stderr, "cfctx-run:", err)
		return 1
	}
	return code
}

func runRequest(args []string) int { return runRequestFD(args, 3) }

func runRequestFD(args []string, fd uintptr) int {
	return runRequestFDWithExecutor(args, fd, run.ExecuteRequest)
}

func runRequestFDWithExecutor(args []string, fd uintptr, execute func(context.Context, run.Request, []string, io.Reader, io.Writer, io.Writer) (int, error)) int {
	ctx, cancel := context.WithCancelCause(context.Background())
	defer cancel(nil)
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
	defer signal.Stop(signals)
	go func() {
		select {
		case received := <-signals:
			if sig, ok := received.(syscall.Signal); ok {
				cancel(run.SignalCause(sig))
			}
		case <-ctx.Done():
		}
	}()
	data, err := run.ReadRequestFD(ctx, fd)
	if err != nil {
		if ctx.Err() != nil {
			return run.CancellationCode(ctx)
		}
		fmt.Fprintln(os.Stderr, "cfctx-run:", err)
		if errors.Is(err, run.ErrRequest) {
			return 2
		}
		return 1
	}
	request, err := run.DecodeRequest(data)
	for i := range data {
		data[i] = 0
	}
	data = nil
	if err != nil {
		fmt.Fprintln(os.Stderr, "cfctx-run: request: invalid request schema or encoding")
		return 2
	}
	code, err := execute(ctx, request, args, os.Stdin, os.Stdout, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cfctx-run:", err)
		return 1
	}
	return code
}
