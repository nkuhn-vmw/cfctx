package main

import (
	"context"
	"flag"
	"fmt"
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
	provider := flags.String("provider", "", "portal or mcp")
	workspace := flags.String("workspace", "", "workspace handle")
	foundation := flags.String("foundation", "", "foundation name")
	capability := flags.String("capability", "", "capability name")
	descriptor := flags.String("descriptor", "", "reviewed non-secret descriptor file")
	if flags.Parse(os.Args[1:]) != nil {
		return 2
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
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
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
