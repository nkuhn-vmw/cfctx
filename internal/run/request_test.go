package run

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func validRequestBytes() []byte {
	return []byte(`{"schema":"cfctx.run.request/v1","targets":{"cf":{"api":"https://api.example.com/","orgGuid":"11111111-1111-1111-1111-111111111111","spaceGuid":"22222222-2222-2222-2222-222222222222"}},"credentials":{"CF_USERNAME":"user","CF_PASSWORD":"pass"}}`)
}

func TestDecodeRequestStrictContract(t *testing.T) {
	cases := map[string][]byte{
		"valid":              validRequestBytes(),
		"duplicate":          bytes.Replace(validRequestBytes(), []byte(`"schema":`), []byte(`"schema":"cfctx.run.request/v1","schema":`), 1),
		"unknown":            bytes.Replace(validRequestBytes(), []byte(`"schema":`), []byte(`"extra":true,"schema":`), 1),
		"case-mismatched":    bytes.Replace(validRequestBytes(), []byte(`"schema":`), []byte(`"Schema":`), 1),
		"nested-case":        bytes.Replace(validRequestBytes(), []byte(`"orgGuid":`), []byte(`"OrgGuid":`), 1),
		"null":               bytes.Replace(validRequestBytes(), []byte(`"api":"https://api.example.com/"`), []byte(`"api":null`), 1),
		"trailing":           append(validRequestBytes(), []byte(` {}`)...),
		"invalid-utf8":       append(validRequestBytes(), 0xff),
		"wrong-schema":       bytes.Replace(validRequestBytes(), []byte("cfctx.run.request/v1"), []byte("cfctx.run.request/v2"), 1),
		"credential-newline": bytes.Replace(validRequestBytes(), []byte(`"CF_PASSWORD":"pass"`), []byte(`"CF_PASSWORD":"bad\npass"`), 1),
		"bad-host":           bytes.Replace(validRequestBytes(), []byte("api.example.com"), []byte("api.example.com evil"), 1),
		"bad-port":           bytes.Replace(validRequestBytes(), []byte("api.example.com/"), []byte("api.example.com:65536/"), 1),
		"empty-port":         bytes.Replace(validRequestBytes(), []byte("api.example.com/"), []byte("api.example.com:/"), 1),
		"bad-uuid-case":      bytes.Replace(validRequestBytes(), []byte("11111111-1111-1111-1111-111111111111"), []byte("11111111-1111-1111-1111-AAAAAAAAAAAA"), 1),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := DecodeRequest(data)
			if (err == nil) != (name == "valid") {
				t.Fatalf("DecodeRequest error = %v", err)
			}
		})
	}
}

func TestRequestSizeBoundary(t *testing.T) {
	base := validRequestBytes()
	for _, size := range []int{RequestMaxBytes, RequestMaxBytes + 1} {
		data := append([]byte(nil), base...)
		padding := size - len(data)
		if padding < 0 {
			t.Fatal("test fixture too large")
		}
		data = append(data[:len(data)-1], bytes.Repeat([]byte(" "), padding)...)
		data = append(data, '}')
		_, err := DecodeRequest(data)
		if (err == nil) != (size == RequestMaxBytes) {
			t.Fatalf("size %d: %v", size, err)
		}
	}
}

func TestDecodeRequestRequiresExactCredentialSet(t *testing.T) {
	for _, replacement := range []string{
		`"credentials":{"CF_USERNAME":"user"}`,
		`"credentials":{"CF_USERNAME":"user","CF_PASSWORD":"pass","BOSH_CLIENT":"x"}`,
	} {
		data := strings.Replace(string(validRequestBytes()), `"credentials":{"CF_USERNAME":"user","CF_PASSWORD":"pass"}`, replacement, 1)
		if _, err := DecodeRequest([]byte(data)); err == nil {
			t.Fatal("accepted non-exact credential set")
		}
	}
}

func TestContractOutputExact(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(ContractJSON), &got); err != nil || len(got) != 3 {
		t.Fatalf("contract JSON: %v", err)
	}
}

func TestReadRequestFDPipeAndCancellation(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	type result struct {
		data []byte
		err  error
	}
	done := make(chan result, 1)
	fd, err := syscall.Dup(int(r.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	go func() { data, err := ReadRequestFD(context.Background(), uintptr(fd)); done <- result{data, err} }()
	if _, err := w.Write(validRequestBytes()); err != nil {
		t.Fatal(err)
	}
	w.Close()
	got := <-done
	if got.err != nil || !bytes.Equal(got.data, validRequestBytes()) {
		t.Fatalf("pipe read: %v", got.err)
	}

	r2, w2, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	fd, err = syscall.Dup(int(r2.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	if err := r2.Close(); err != nil {
		t.Fatal(err)
	}
	cancelDone := make(chan error, 1)
	go func() { _, err := ReadRequestFD(ctx, uintptr(fd)); cancelDone <- err }()
	cancel()
	if err := <-cancelDone; err == nil {
		t.Fatal("cancellation did not stop pending read")
	}
	w2.Close()
}

func TestReadRequestFDBadFDOverflowAndDeadline(t *testing.T) {
	if _, err := ReadRequestFD(context.Background(), ^uintptr(0)); err != ErrRequestPipe {
		t.Fatalf("invalid fd error = %v", err)
	}
	file, err := os.CreateTemp(t.TempDir(), "regular")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ReadRequestFD(context.Background(), file.Fd()); err != ErrRequestPipe {
		t.Fatalf("regular file error = %v", err)
	}
	file.Close()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	fd, err := syscall.Dup(int(r.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	r.Close()
	start := time.Now()
	if _, err := readRequestFD(context.Background(), uintptr(fd), 30*time.Millisecond); err != ErrRequestTimeout {
		t.Fatalf("hanging writer error = %v", err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("request deadline was not enforced")
	}
	w.Close()

	r2, w2, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	fd, err = syscall.Dup(int(r2.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	r2.Close()
	writeDone := make(chan error, 1)
	go func() {
		_, writeErr := w2.Write(bytes.Repeat([]byte{' '}, RequestMaxBytes+1))
		writeDone <- writeErr
		w2.Close()
	}()
	if _, err := ReadRequestFD(context.Background(), uintptr(fd)); err != ErrRequest {
		t.Fatalf("overflow error = %v", err)
	}
	<-writeDone
}

func TestExecuteRequestUsesIsolatedCFAndPreservesStatus(t *testing.T) {
	decoded, toolDir := fixtureRequest(t)
	marker := t.TempDir() + "/child-state"
	code, err := ExecuteRequest(context.Background(), decoded, []string{toolDir + "/child", marker}, nil, io.Discard, io.Discard)
	if err != nil || code != 17 {
		t.Fatalf("request execution returned %d: %v", code, err)
	}
	root, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(string(root)); !os.IsNotExist(err) {
		t.Fatal("request execution left private CF state")
	}
}

func fixtureRequest(t *testing.T) (Request, string) {
	t.Helper()
	toolDir := tools(t)
	data := bytes.Replace(validRequestBytes(), []byte("api.example.com"), []byte("api.example.invalid"), 1)
	data = bytes.Replace(data, []byte(`"CF_USERNAME":"user"`), []byte(`"CF_USERNAME":"fixture-user"`), 1)
	data = bytes.Replace(data, []byte(`"CF_PASSWORD":"pass"`), []byte(`"CF_PASSWORD":"fixture-$(touch unsafe)-password"`), 1)
	request, err := DecodeRequest(data)
	if err != nil {
		t.Fatal(err)
	}
	return request, toolDir
}

func TestExecuteRequestPipedStdinAndFDIsolation(t *testing.T) {
	request, toolDir := fixtureRequest(t)
	for _, mode := range []string{"readline", "fd3"} {
		t.Run(mode, func(t *testing.T) {
			marker := filepath.Join(t.TempDir(), "child")
			input := io.Reader(nil)
			if mode == "readline" {
				input = strings.NewReader("pipe-data\n")
			}
			code, err := ExecuteRequest(context.Background(), request, []string{filepath.Join(toolDir, "child"), marker, mode}, input, io.Discard, io.Discard)
			if err != nil || code != 0 {
				t.Fatalf("request child returned %d: %v", code, err)
			}
			if mode == "readline" {
				data, err := os.ReadFile(marker)
				if err != nil || string(data) != "pipe-data\n" {
					t.Fatalf("piped stdin = %q: %v", data, err)
				}
			}
		})
	}
}

func TestExecuteRequestRejectsBadParentAndDisabledTLS(t *testing.T) {
	request, toolDir := fixtureRequest(t)
	for _, envName := range []string{"WRONG_PARENT", "WRONG_SSL"} {
		t.Run(envName, func(t *testing.T) {
			t.Setenv(envName, "1")
			marker := filepath.Join(t.TempDir(), "must-not-run")
			_, err := ExecuteRequest(context.Background(), request, []string{filepath.Join(toolDir, "child"), marker}, nil, io.Discard, io.Discard)
			if err == nil {
				t.Fatal("invalid target verification succeeded")
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatal("child ran after target verification failure")
			}
		})
	}
}

func TestExecuteRequestSignalsLeaderAndStubbornDescendants(t *testing.T) {
	request, toolDir := fixtureRequest(t)
	for _, mode := range []string{"stubborn", "leader-exits"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithCancelCause(context.Background())
			defer cancel(nil)
			marker := filepath.Join(t.TempDir(), "child")
			done := make(chan int, 1)
			go func() {
				code, _ := ExecuteRequest(ctx, request, []string{filepath.Join(toolDir, "child"), marker, mode}, nil, io.Discard, io.Discard)
				done <- code
			}()
			deadline := time.Now().Add(15 * time.Second)
			for time.Now().Before(deadline) {
				if _, err := os.Stat(marker + ".descendant"); err == nil {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			if _, err := os.Stat(marker + ".descendant"); err != nil {
				t.Fatal("signal fixture did not start")
			}
			pgidBytes, err := os.ReadFile(marker + ".pgid")
			if err != nil {
				t.Fatal(err)
			}
			started := time.Now()
			cancel(SignalCause(syscall.SIGTERM))
			if code := <-done; code != 143 {
				t.Fatalf("cancellation code = %d", code)
			}
			if elapsed := time.Since(started); elapsed < 2500*time.Millisecond {
				t.Fatalf("runner returned before stubborn group grace: %s", elapsed)
			}
			var pgid int
			if _, err := fmt.Sscanf(string(pgidBytes), "%d", &pgid); err != nil {
				t.Fatal(err)
			}
			limit := time.Now().Add(time.Second)
			for time.Now().Before(limit) {
				if err := syscall.Kill(-pgid, 0); err == syscall.ESRCH {
					return
				}
				time.Sleep(20 * time.Millisecond)
			}
			t.Fatal("signal handling returned while process group remained")
		})
	}
}

func TestRequestCancellationCodeTracksSignal(t *testing.T) {
	for _, test := range []struct {
		sig  syscall.Signal
		want int
	}{{syscall.SIGINT, 130}, {syscall.SIGTERM, 143}, {syscall.SIGHUP, 129}, {syscall.SIGQUIT, 131}} {
		ctx, cancel := context.WithCancelCause(context.Background())
		cancel(SignalCause(test.sig))
		if got := CancellationCode(ctx); got != test.want {
			t.Errorf("signal %v: got %d want %d", test.sig, got, test.want)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got := CancellationCode(ctx); got != 143 {
		t.Errorf("plain cancellation: got %d", got)
	}
}
