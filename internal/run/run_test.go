package run

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const orgID = "11111111-1111-1111-1111-111111111111"
const spaceID = "22222222-2222-2222-2222-222222222222"
const directorID = "33333333-3333-3333-3333-333333333333"

func fixture() (Profile, Descriptor, Selection) {
	s := Selection{"demo", "cdc", "deploy"}
	targets := Targets{CF: &CFTarget{"https://api.example.invalid", orgID, spaceID}}
	p := Profile{1, s.Workspace, s.Foundation, s.Capability, targets, map[string]string{"CF_USERNAME": "fixture-user", "CF_PASSWORD": "fixture-$(touch unsafe)-password"}}
	d := Descriptor{Version: 1, Workspace: s.Workspace, Foundation: s.Foundation, Capability: s.Capability, Namespace: "/kuhn-labs/ws/demo/contexts/cdc/deploy", Targets: targets, CredentialFields: []string{"CF_USERNAME", "CF_PASSWORD"}, PortalContext: "cdc"}
	return p, d, s
}
func TestProfileValidation(t *testing.T) {
	for _, kind := range []string{"valid", "unknown-field", "duplicate", "trailing", "wrong-workspace", "wrong-api", "extra-credential", "wrong-guid", "selector-shell"} {
		t.Run(kind, func(t *testing.T) {
			p, d, s := fixture()
			data, _ := json.Marshal(p)
			switch kind {
			case "unknown-field":
				data = bytes.Replace(data, []byte(`"version":1`), []byte(`"version":1,"shell":"eval"`), 1)
			case "duplicate":
				data = bytes.Replace(data, []byte(`"version":1`), []byte(`"version":1,"version":1`), 1)
			case "trailing":
				data = append(data, []byte(`{}`)...)
			case "wrong-workspace":
				p.Workspace = "other"
				data, _ = json.Marshal(p)
			case "wrong-api":
				p.Targets.CF = &CFTarget{"https://evil.example.invalid", orgID, spaceID}
				data, _ = json.Marshal(p)
			case "extra-credential":
				p.Credentials["OM_PASSWORD"] = "forbidden"
				data, _ = json.Marshal(p)
			case "wrong-guid":
				d.Targets.CF = &CFTarget{"https://api.example.invalid", "bad", spaceID}
			case "selector-shell":
				s.Workspace = "$(touch unsafe)"
			}
			var decoded Profile
			err := DecodeStrict(data, &decoded)
			if err == nil {
				err = Validate(decoded, d, s)
			}
			if (err == nil) != (kind == "valid") {
				t.Fatalf("unexpected validation for %s: %v", kind, err)
			}
		})
	}
}
func TestCleanEnvironment(t *testing.T) {
	env := CleanEnvironment([]string{"CF_HOME=old", "BOSH_CLIENT=admin", "OM_PASSWORD=old", "UAA_TOKEN=old", "CREDHUB_SECRET=old", "VCAP_SERVICES=old", "KLPORTAL_TOKEN=old", "PATH=/bin", "TERM=xterm"})
	if strings.Join(env, ";") != "PATH=/bin;TERM=xterm" {
		t.Fatal("inherited credential remained")
	}
}

// The subprocess fixture exercises the real exec/env/file boundary without a foundation.
func TestCLIProcess(t *testing.T) {
	if os.Getenv("RUN_FIXTURE") != "1" {
		return
	}
	args := os.Args
	for len(args) > 0 && args[0] != "--" {
		args = args[1:]
	}
	args = args[1:]
	tool, args := args[0], args[1:]
	for _, arg := range args {
		if strings.Contains(arg, "fixture-$(touch unsafe)-password") {
			os.Exit(90)
		}
	}
	switch tool {
	case "cf":
		switch args[0] {
		case "api":
			if args[1] != "https://api.example.invalid" {
				os.Exit(91)
			}
		case "auth":
			if os.Getenv("FAIL_AUTH") == "1" {
				fmt.Fprintln(os.Stderr, "SECRET ERROR BODY")
				os.Exit(1)
			}
			if os.Getenv("CF_USERNAME") != "fixture-user" || os.Getenv("CF_PASSWORD") != "fixture-$(touch unsafe)-password" {
				os.Exit(92)
			}
		case "curl":
			if strings.Contains(args[1], "organizations") {
				fmt.Printf(`{"guid":%q,"name":"fixture-org"}`, orgID)
			} else {
				fmt.Printf(`{"guid":%q,"name":"fixture-space","relationships":{"organization":{"data":{"guid":%q}}}}`, spaceID, orgID)
			}
		case "target":
			root := filepath.Join(os.Getenv("CF_HOME"), ".cf")
			os.MkdirAll(root, 0700)
			id := spaceID
			if os.Getenv("WRONG_TARGET") == "1" {
				id = orgID
			}
			data := fmt.Sprintf(`{"Target":"https://api.example.invalid","OrganizationFields":{"GUID":%q},"SpaceFields":{"GUID":%q},"SSLDisabled":false}`, orgID, id)
			os.WriteFile(filepath.Join(root, "config.json"), []byte(data), 0600)
		}
	case "bosh":
		if os.Getenv("BOSH_CONFIG") == "" || os.Getenv("BOSH_CLIENT") == "" {
			os.Exit(94)
		}
		id := directorID
		if os.Getenv("WRONG_DIRECTOR") == "1" {
			id = orgID
		}
		fmt.Printf(`{"uuid":%q}`, id)
	case "klportal":
		if os.Getenv("KLPORTAL_TOKEN") != "" {
			os.Exit(95)
		}
		if os.Getenv("FAIL_LOOKUP") == "1" {
			fmt.Fprintln(os.Stderr, "SECRET ERROR BODY")
			os.Exit(1)
		}
		p, _, s := fixture()
		data, _ := json.Marshal(p)
		path, _ := s.Path()
		detail, _ := json.Marshal(map[string]any{"name": path, "type": "json", "value": string(data), "updatedAt": "now"})
		fmt.Print(string(detail))
	case "child":
		if os.Getenv("CF_PASSWORD") != "" || os.Getenv("OM_PASSWORD") != "" || os.Getenv("CREDHUB_SECRET") != "" {
			os.Exit(96)
		}
		root := os.Getenv("CF_HOME")
		info, err := os.Stat(root)
		if err != nil || info.Mode().Perm() != 0700 {
			os.Exit(97)
		}
		os.WriteFile(args[0], []byte(root), 0600)
		if len(args) > 1 && args[1] == "wait" {
			time.Sleep(10 * time.Second)
		}
		os.Exit(17)
	}
	os.Exit(0)
}
func tools(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("TEST_EXECUTABLE", exe)
	t.Setenv("RUN_FIXTURE", "1")
	for _, name := range []string{"cf", "bosh", "klportal", "child"} {
		script := fmt.Sprintf("#!/bin/sh\nexec \"$TEST_EXECUTABLE\" -test.run=TestCLIProcess -- %s \"$@\"\n", name)
		if err := os.WriteFile(filepath.Join(root, name), []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", root+string(os.PathListSeparator)+os.Getenv("PATH"))
	return root
}
func TestExecuteSuccessCleanupAndExitCode(t *testing.T) {
	tools(t)
	p, d, s := fixture()
	t.Setenv("CF_HOME", "inherited")
	t.Setenv("OM_PASSWORD", "inherited")
	t.Setenv("CREDHUB_SECRET", "inherited")
	marker := filepath.Join(t.TempDir(), "marker")
	var output bytes.Buffer
	code, err := Execute(context.Background(), p, d, s, []string{"child", marker}, nil, &output, &output)
	if err != nil || code != 17 {
		t.Fatalf("code %d, err %v", code, err)
	}
	root, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(string(root)); !os.IsNotExist(err) {
		t.Fatal("temporary token state survived")
	}
	if output.Len() != 0 {
		t.Fatal("setup output exposed")
	}
}

func TestExecuteNormalizesTrailingCFAPISlash(t *testing.T) {
	tools(t)
	p, d, s := fixture()
	p.Targets.CF.API += "/"
	d.Targets = p.Targets
	code, err := Execute(context.Background(), p, d, s, []string{"child", filepath.Join(t.TempDir(), "marker")}, nil, io.Discard, io.Discard)
	if err != nil || code != 17 {
		t.Fatalf("trailing-slash API failed: code %d, err %v", code, err)
	}
}
func TestExecuteDenialsDoNotRunChild(t *testing.T) {
	tools(t)
	for _, key := range []string{"FAIL_AUTH", "WRONG_TARGET", "WRONG_DIRECTOR"} {
		t.Run(key, func(t *testing.T) {
			p, d, s := fixture()
			if key == "WRONG_DIRECTOR" {
				p.Targets.BOSH = &BOSHTarget{"https://director.example.invalid", directorID, "demo"}
				d.Targets = p.Targets
				d.CredentialFields = append(d.CredentialFields, "BOSH_CLIENT", "BOSH_CLIENT_SECRET", "BOSH_CA_CERT")
				p.Credentials["BOSH_CLIENT"] = "fixture"
				p.Credentials["BOSH_CLIENT_SECRET"] = "fixture-secret"
				p.Credentials["BOSH_CA_CERT"] = "fixture-ca"
			}
			t.Setenv(key, "1")
			marker := filepath.Join(t.TempDir(), "marker")
			var output bytes.Buffer
			_, err := Execute(context.Background(), p, d, s, []string{"child", marker}, nil, &output, &output)
			if err == nil {
				t.Fatal("denial succeeded")
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatal("child ran after denial")
			}
			if output.Len() != 0 {
				t.Fatal("secret-bearing setup error exposed")
			}
		})
	}
}
func TestPortalCapturesValueAndFailsClosedAfterSuccess(t *testing.T) {
	tools(t)
	t.Setenv("KLPORTAL_TOKEN", "admin-override")
	_, d, s := fixture()
	got, err := (Portal{Context: d.PortalContext}).Resolve(context.Background(), s)
	if err != nil || Validate(got, d, s) != nil {
		t.Fatal("portal profile failed")
	}
	t.Setenv("FAIL_LOOKUP", "1")
	got, err = (Portal{Context: d.PortalContext}).Resolve(context.Background(), s)
	if err == nil || got.Version != 0 {
		t.Fatal("lookup fell back to previous profile")
	}
	if strings.Contains(err.Error(), "SECRET") {
		t.Fatal("provider error disclosed raw body")
	}
}
func TestConcurrentContextsAndSignalCleanup(t *testing.T) {
	tools(t)
	p, d, s := fixture()
	root := t.TempDir()
	markers := []string{filepath.Join(root, "one"), filepath.Join(root, "two")}
	var wg sync.WaitGroup
	for _, marker := range markers {
		wg.Add(1)
		go func(path string) {
			defer wg.Done()
			code, err := Execute(context.Background(), p, d, s, []string{"child", path}, nil, io.Discard, io.Discard)
			if err != nil || code != 17 {
				t.Errorf("concurrent execution failed: %v", err)
			}
		}(marker)
	}
	wg.Wait()
	one, _ := os.ReadFile(markers[0])
	two, _ := os.ReadFile(markers[1])
	if len(one) == 0 || bytes.Equal(one, two) {
		t.Fatal("contexts shared state")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	marker := filepath.Join(root, "signal")
	done := make(chan int, 1)
	go func() {
		code, _ := Execute(ctx, p, d, s, []string{"child", marker, "wait"}, nil, io.Discard, io.Discard)
		done <- code
	}()
	limit := time.After(15 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		select {
		case <-limit:
			t.Fatal("child did not start")
		default:
			time.Sleep(10 * time.Millisecond)
		}
	}
	state, _ := os.ReadFile(marker)
	cancel()
	if code := <-done; code != 130 {
		t.Fatalf("cancel code %d", code)
	}
	if _, err := os.Stat(string(state)); !os.IsNotExist(err) {
		t.Fatal("cancel left state")
	}
}
func TestMCPDirectSSEAndStateless(t *testing.T) {
	for _, session := range []bool{false, true} {
		t.Run(fmt.Sprint(session), func(t *testing.T) {
			p, d, s := fixture()
			profileJSON, _ := json.Marshal(p)
			path, _ := s.Path()
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "DELETE" {
					w.WriteHeader(204)
					return
				}
				var body struct {
					Method string          `json:"method"`
					ID     int             `json:"id"`
					Params json.RawMessage `json:"params"`
				}
				if json.NewDecoder(r.Body).Decode(&body) != nil {
					t.Error("bad request")
				}
				calls++
				if session && calls > 1 && r.Header.Get("Mcp-Session-Id") != "fixture-session" {
					t.Error("missing session")
				}
				switch body.Method {
				case "initialize":
					if session {
						w.Header().Set("Mcp-Session-Id", "fixture-session")
					}
					w.Header().Set("Content-Type", "text/event-stream")
					fmt.Fprint(w, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}\n\n")
				case "notifications/initialized":
					w.WriteHeader(202)
				case "tools/call":
					var params struct {
						Name      string `json:"name"`
						Arguments struct {
							Path string `json:"path"`
						} `json:"arguments"`
					}
					json.Unmarshal(body.Params, &params)
					if params.Name != "secret_get" || params.Arguments.Path != path {
						t.Error("wrong secret path")
					}
					detail, _ := json.Marshal(map[string]any{"value": string(profileJSON), "updatedAt": "now", "stale": false})
					json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 2, "result": map[string]any{"content": []any{map[string]string{"type": "text", "text": string(detail)}}}})
				default:
					t.Error("unexpected MCP method")
				}
			}))
			defer server.Close()
			got, err := (MCP{Endpoint: server.URL + "/mcp"}).Resolve(context.Background(), s)
			if err != nil || Validate(got, d, s) != nil {
				t.Fatalf("MCP profile failed: %v", err)
			}
			if calls != 3 {
				t.Fatalf("calls %d", calls)
			}
		})
	}
}
func TestMCPDenialsAndNoRedirect(t *testing.T) {
	_, _, s := fixture()
	for _, body := range []string{`{"jsonrpc":"2.0","id":1,"error":{"message":"SECRET ERROR BODY"}}`, `{"jsonrpc":"2.0","id":9,"result":{}}`, `not-json`} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) }))
		_, err := (MCP{Endpoint: server.URL + "/mcp"}).Resolve(context.Background(), s)
		server.Close()
		if err == nil || strings.Contains(err.Error(), "SECRET") {
			t.Fatal("unsafe MCP failure")
		}
	}
	followed := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { followed = true }))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 307) }))
	defer redirect.Close()
	_, err := (MCP{Endpoint: redirect.URL + "/mcp"}).Resolve(context.Background(), s)
	if err == nil || followed {
		t.Fatal("MCP followed redirect")
	}
	if _, err = (MCP{Endpoint: "https://public.example.invalid/mcp"}).Resolve(context.Background(), s); err == nil {
		t.Fatal("public endpoint allowed")
	}
}
