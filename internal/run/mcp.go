package run

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const protocol = "2024-11-05"

type MCP struct{ Endpoint string }
type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int             `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   json.RawMessage `json:"error"`
}

func loopback(endpoint string) bool {
	u, err := url.Parse(endpoint)
	return err == nil && u.Scheme == "http" && (u.Hostname() == "127.0.0.1" || u.Hostname() == "::1") && u.Port() != "" && u.Path == "/mcp" && u.RawPath == "" && u.RawQuery == "" && u.Fragment == "" && u.User == nil
}
func decodeRPC(data []byte, id int) (rpcResponse, error) {
	var r rpcResponse
	if DecodeStrict(data, &r) != nil || r.JSONRPC != "2.0" || r.ID != id || len(r.Error) != 0 || len(r.Result) == 0 {
		return r, ErrProvider
	}
	return r, nil
}
func rpc(ctx context.Context, client *http.Client, endpoint, session, method string, id int, params any) (rpcResponse, string, error) {
	body := map[string]any{"jsonrpc": "2.0", "method": method}
	if id != 0 {
		body["id"] = id
	}
	if params != nil {
		body["params"] = params
	}
	data, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, "POST", endpoint, bytes.NewReader(data))
	if err != nil {
		return rpcResponse{}, "", ErrProvider
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("MCP-Protocol-Version", protocol)
	if session != "" {
		req.Header.Set("Mcp-Session-Id", session)
	}
	resp, err := client.Do(req)
	if err != nil {
		return rpcResponse{}, "", ErrProvider
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return rpcResponse{}, "", ErrProvider
	}
	sid := resp.Header.Get("Mcp-Session-Id")
	if sid == "" {
		sid = session
	}
	if id == 0 {
		return rpcResponse{}, sid, nil
	}
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		// Stop as soon as our response event arrives; persistent SSE need not close.
		scanner := bufio.NewScanner(io.LimitReader(resp.Body, MaxBytes+1))
		scanner.Buffer(make([]byte, 4096), MaxBytes)
		event := []byte{}
		total := 0
		for scanner.Scan() {
			line := scanner.Text()
			total += len(line) + 1
			if total > MaxBytes {
				return rpcResponse{}, "", ErrProvider
			}
			if line == "" && len(event) > 0 {
				var candidate struct {
					ID int `json:"id"`
				}
				if json.Unmarshal(event, &candidate) == nil && candidate.ID == id {
					r, err := decodeRPC(event, id)
					return r, sid, err
				}
				event = nil
			} else if strings.HasPrefix(line, "data:") {
				event = append(event, []byte(strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))...)
				event = append(event, '\n')
			}
		}
		if len(event) > 0 {
			r, err := decodeRPC(event, id)
			return r, sid, err
		}
		return rpcResponse{}, "", ErrProvider
	}
	data, err = io.ReadAll(io.LimitReader(resp.Body, MaxBytes+1))
	if err != nil {
		return rpcResponse{}, "", ErrProvider
	}
	r, err := decodeRPC(data, id)
	return r, sid, err
}
func (p MCP) Resolve(ctx context.Context, s Selection) (Profile, error) {
	var profile Profile
	path, err := s.Path()
	if err != nil || !loopback(p.Endpoint) {
		return profile, ErrInvalid
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 30 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	init, sid, err := rpc(ctx, client, p.Endpoint, "", "initialize", 1, map[string]any{"protocolVersion": protocol, "capabilities": map[string]any{}, "clientInfo": map[string]string{"name": "cfctx-run", "version": "1"}})
	if err != nil {
		return profile, err
	}
	var initialized struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	if json.Unmarshal(init.Result, &initialized) != nil || initialized.ProtocolVersion != protocol {
		return profile, ErrProvider
	}
	// Session teardown is best effort and independent of the expired/cancelled lookup context.
	if sid != "" {
		defer func() {
			end, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			req, _ := http.NewRequestWithContext(end, "DELETE", p.Endpoint, nil)
			req.Header.Set("Mcp-Session-Id", sid)
			req.Header.Set("MCP-Protocol-Version", protocol)
			resp, err := client.Do(req)
			if err == nil {
				resp.Body.Close()
			}
		}()
	}
	if _, _, err = rpc(ctx, client, p.Endpoint, sid, "notifications/initialized", 0, nil); err != nil {
		return profile, err
	}
	result, _, err := rpc(ctx, client, p.Endpoint, sid, "tools/call", 2, map[string]any{"name": "secret_get", "arguments": map[string]string{"path": path}})
	if err != nil {
		return profile, err
	}
	var tool struct {
		IsError    bool            `json:"isError"`
		Structured json.RawMessage `json:"structuredContent"`
		Content    []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if json.Unmarshal(result.Result, &tool) != nil || tool.IsError {
		return profile, ErrProvider
	}
	detail := tool.Structured
	if len(detail) == 0 {
		if len(tool.Content) != 1 || tool.Content[0].Type != "text" {
			return profile, ErrProvider
		}
		detail = []byte(tool.Content[0].Text)
	}
	var secret struct {
		Name      string `json:"name"`
		Value     string `json:"value"`
		UpdatedAt string `json:"updatedAt"`
		Stale     *bool  `json:"stale"`
	}
	if DecodeStrict(detail, &secret) != nil || (secret.Name != "" && secret.Name != path) || secret.Stale == nil || *secret.Stale || DecodeStrict([]byte(secret.Value), &profile) != nil {
		return profile, ErrProvider
	}
	return profile, nil
}
