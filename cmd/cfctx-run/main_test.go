package main

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/nkuhn-vmw/cfctx/internal/run"
)

func TestRequestFDOptionPresenceIsValidated(t *testing.T) {
	original := os.Args
	defer func() { os.Args = original }()
	for _, args := range [][]string{
		{"cfctx-run", "--request-fd", "-1", "--", "/usr/bin/true"},
		{"cfctx-run", "--contract", "--request-fd", "-1"},
		{"cfctx-run", "--request-fd", "4", "--", "/usr/bin/true"},
	} {
		os.Args = args
		if code := mainRun(); code != 2 {
			t.Errorf("mainRun(%q) = %d, want 2", args, code)
		}
	}
}

func TestLegacyPortalProviderIsRejected(t *testing.T) {
	dir := t.TempDir()
	descriptor := filepath.Join(dir, "descriptor.json")
	const validLegacyDescriptor = `{"version":1,"workspace":"demo","foundation":"cdc","capability":"deploy","namespace":"/kuhn-labs/ws/demo/contexts/cdc/deploy","targets":{"cf":{"api":"https://api.example.invalid","orgGuid":"11111111-1111-1111-1111-111111111111","spaceGuid":"22222222-2222-2222-2222-222222222222"}},"credentialFields":["CF_USERNAME","CF_PASSWORD"],"portalContext":"dev"}`
	if err := os.WriteFile(descriptor, []byte(validLegacyDescriptor), 0600); err != nil {
		t.Fatal(err)
	}
	// If the removed adapter were still enabled, an empty PATH makes lookup
	// fail locally instead of invoking any installed external provider.
	t.Setenv("PATH", dir)
	original := os.Args
	defer func() { os.Args = original }()
	os.Args = []string{"cfctx-run", "--provider", "portal", "--workspace", "demo", "--foundation", "cdc", "--capability", "deploy", "--descriptor", descriptor, "--", "/usr/bin/true"}
	if code := mainRun(); code != 2 {
		t.Fatalf("legacy provider exit code = %d, want 2", code)
	}
}

func TestContractCommandPrintsExactOutput(t *testing.T) {
	originalArgs, originalStdout := os.Args, os.Stdout
	defer func() { os.Args, os.Stdout = originalArgs, originalStdout }()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	os.Args = []string{"cfctx-run", "--contract"}
	if code := mainRun(); code != 0 {
		t.Fatalf("--contract exit code = %d", code)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if _, err := output.ReadFrom(r); err != nil {
		t.Fatal(err)
	}
	const expected = `{"schemas":["cfctx.run.request/v1"],"requestMaxBytes":65536,"terminalStdin":"eof"}` + "\n"
	if output.String() != expected {
		t.Fatalf("--contract output %q", output.String())
	}
}

func TestInvalidRequestSchemaReturnsTwo(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte(`{"schema":"cfctx.run.request/v2"}`)); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	fd, err := syscall.Dup(int(r.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	if code := runRequestFD([]string{"/usr/bin/true"}, uintptr(fd)); code != 2 {
		t.Fatalf("invalid schema exit code = %d, want 2", code)
	}
}

func TestOversizeRequestReturnsTwo(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	fd, err := syscall.Dup(int(r.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	r.Close()
	writeDone := make(chan struct{}, 1)
	go func() { _, _ = w.Write(bytes.Repeat([]byte{' '}, 65537)); _ = w.Close(); writeDone <- struct{}{} }()
	if code := runRequestFD([]string{"/usr/bin/true"}, uintptr(fd)); code != 2 {
		t.Fatalf("oversize request exit code = %d, want 2", code)
	}
	<-writeDone
}

func TestRequestSignalIsCapturedAndMapped(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	fd, err := syscall.Dup(int(r.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	r.Close()
	request := `{"schema":"cfctx.run.request/v1","targets":{"cf":{"api":"https://api.example.com","orgGuid":"11111111-1111-1111-1111-111111111111","spaceGuid":"22222222-2222-2222-2222-222222222222"}},"credentials":{"CF_USERNAME":"test-user","CF_PASSWORD":"test-pass"}}`
	writeDone := make(chan struct{}, 1)
	go func() { _, _ = w.Write([]byte(request)); _ = w.Close(); writeDone <- struct{}{} }()
	done := make(chan int, 1)
	entered := make(chan struct{})
	execute := func(ctx context.Context, _ run.Request, _ []string, _ io.Reader, _, _ io.Writer) (int, error) {
		close(entered)
		<-ctx.Done()
		return run.CancellationCode(ctx), nil
	}
	go func() { done <- runRequestFDWithExecutor([]string{"fixture"}, uintptr(fd), execute) }()
	<-writeDone
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("request executor did not start")
	}
	if err := syscall.Kill(os.Getpid(), syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	select {
	case code := <-done:
		if code != 130 {
			t.Fatalf("SIGINT exit code = %d, want 130", code)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("runner did not capture SIGINT")
	}
}
