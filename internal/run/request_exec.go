package run

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

var ErrRequestPipe = errors.New("request: unavailable request pipe")
var ErrRequestTimeout = errors.New("request: timed out reading request")

type SignalCause syscall.Signal

func (s SignalCause) Error() string { return "runner cancelled by signal" }

// ReadRequestFD reads one bounded JSON request from an anonymous pipe. Nonblocking
// reads let the deadline and cancellation work even when the producer stays open.
func ReadRequestFD(ctx context.Context, fd uintptr) ([]byte, error) {
	return readRequestFD(ctx, fd, 30*time.Second)
}

func readRequestFD(ctx context.Context, fd uintptr, timeout time.Duration) ([]byte, error) {
	var stat syscall.Stat_t
	if syscall.Fstat(int(fd), &stat) != nil || stat.Mode&syscall.S_IFMT != syscall.S_IFIFO {
		return nil, ErrRequestPipe
	}
	syscall.CloseOnExec(int(fd))
	if err := syscall.SetNonblock(int(fd), true); err != nil {
		return nil, ErrRequestPipe
	}
	defer syscall.Close(int(fd))
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	data := make([]byte, 0, 4096)
	buf := make([]byte, 4096)
	for {
		n, err := syscall.Read(int(fd), buf)
		if n > 0 {
			if len(data)+n > RequestMaxBytes {
				return nil, ErrRequest
			}
			data = append(data, buf[:n]...)
		}
		if n == 0 && err == nil || err == io.EOF {
			return data, nil
		}
		if err != nil && err != syscall.EAGAIN && err != syscall.EWOULDBLOCK && err != syscall.EINTR {
			return nil, ErrRequestPipe
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-deadline.C:
			return nil, ErrRequestTimeout
		case <-tick.C:
		}
	}
}

func cancellationCode(ctx context.Context) int {
	if cause := context.Cause(ctx); cause != nil {
		if sig, ok := cause.(SignalCause); ok {
			return 128 + int(sig)
		}
	}
	return 143
}

// CancellationCode exposes the contract's signal-derived child status to CLI glue.
func CancellationCode(ctx context.Context) int { return cancellationCode(ctx) }

// ExecuteRequest consumes the v1 request without a descriptor or provider lookup.
func ExecuteRequest(ctx context.Context, request Request, args []string, in io.Reader, out, errOut io.Writer) (int, error) {
	if request.Schema != RequestSchema || request.Targets.CF == nil || len(args) == 0 {
		return 1, ErrRequest
	}
	p := Profile{Version: 1, Targets: Targets{CF: request.Targets.CF}, Credentials: request.Credentials}
	root, err := os.MkdirTemp("", "cfctx-run-")
	if err != nil {
		return 1, errors.New("spawn: unable to create private state")
	}
	defer os.RemoveAll(root)
	setup, cancel := context.WithTimeout(ctx, 60*time.Second)
	env, err := prepare(setup, p, root)
	cancel()
	if err != nil {
		if ctx.Err() != nil {
			return cancellationCode(ctx), nil
		}
		return 1, errors.New("authenticate: workspace authentication or target verification failed")
	}
	childEnv := make([]string, 0, len(env))
	for _, item := range env {
		if !strings.HasPrefix(item, "CF_USERNAME=") && !strings.HasPrefix(item, "CF_PASSWORD=") {
			childEnv = append(childEnv, item)
		}
	}
	childStdin := in
	if file, ok := in.(*os.File); ok && terminalIsTTY(file.Fd()) {
		childStdin = nil
	}
	cmd := process(ctx, childEnv, args[0], args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = childStdin, out, errOut
	if err := waitProcess(ctx, cmd); err != nil {
		if ctx.Err() != nil {
			return cancellationCode(ctx), nil
		}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code := exit.ExitCode()
			if code < 0 {
				code = 128 + int(exit.Sys().(syscall.WaitStatus).Signal())
			}
			return code, nil
		}
		return 1, errors.New("spawn: workspace child command could not start")
	}
	if ctx.Err() != nil {
		return cancellationCode(ctx), nil
	}
	return 0, nil
}
