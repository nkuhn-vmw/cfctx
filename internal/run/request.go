package run

import (
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode/utf8"
)

const RequestMaxBytes = 65536
const RequestSchema = "cfctx.run.request/v1"
const ContractJSON = `{"schemas":["cfctx.run.request/v1"],"requestMaxBytes":65536,"terminalStdin":"eof"}`

var ErrRequest = errors.New("request: invalid request")

type Request struct {
	Schema      string            `json:"schema"`
	Targets     RequestTargets    `json:"targets"`
	Credentials map[string]string `json:"credentials"`
}
type RequestTargets struct {
	CF *CFTarget `json:"cf"`
}

func validCFOrigin(raw string) bool {
	if raw == "" || strings.ContainsAny(raw, " \t\r\n%") {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Opaque != "" || u.Host == "" || strings.HasSuffix(u.Host, ":") || u.User != nil || u.RawQuery != "" || u.ForceQuery || strings.Contains(raw, "#") || u.Fragment != "" || u.RawFragment != "" || u.RawPath != "" || (u.Path != "" && u.Path != "/") {
		return false
	}
	host := u.Hostname()
	if host == "" || strings.Contains(host, "%") || strings.HasSuffix(host, ".") {
		return false
	}
	if ip := net.ParseIP(host); ip == nil {
		if len(host) > 253 {
			return false
		}
		for _, label := range strings.Split(host, ".") {
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
				return false
			}
			for _, r := range label {
				if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-') {
					return false
				}
			}
		}
	}
	if port := u.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return false
		}
	}
	return true
}

// DecodeRequest accepts exactly the documented request and rejects duplicate
// keys, invalid UTF-8 and every non-v1 extension before CF setup can begin.
func DecodeRequest(data []byte) (Request, error) {
	var request Request
	if len(data) == 0 || len(data) > RequestMaxBytes || !utf8.Valid(data) || DecodeStrict(data, &request) != nil {
		return request, ErrRequest
	}
	var root, targets, cf, credentials map[string]json.RawMessage
	if json.Unmarshal(data, &root) != nil || !hasExactKeys(root, "schema", "targets", "credentials") ||
		json.Unmarshal(root["targets"], &targets) != nil || !hasExactKeys(targets, "cf") ||
		json.Unmarshal(targets["cf"], &cf) != nil || !hasExactKeys(cf, "api", "orgGuid", "spaceGuid") ||
		json.Unmarshal(root["credentials"], &credentials) != nil || !hasExactKeys(credentials, "CF_USERNAME", "CF_PASSWORD") {
		return request, ErrRequest
	}
	if request.Schema != RequestSchema || request.Targets.CF == nil || len(request.Credentials) != 2 {
		return request, ErrRequest
	}
	t := request.Targets.CF
	if !validCFOrigin(t.API) || !uuid.MatchString(t.OrgGUID) || !uuid.MatchString(t.SpaceGUID) {
		return request, ErrRequest
	}
	for _, key := range []string{"CF_USERNAME", "CF_PASSWORD"} {
		value, ok := request.Credentials[key]
		if !ok || value == "" || strings.ContainsAny(value, "\x00\r\n") {
			return request, ErrRequest
		}
	}
	return request, nil
}

func hasExactKeys(object map[string]json.RawMessage, names ...string) bool {
	if object == nil || len(object) != len(names) {
		return false
	}
	for _, name := range names {
		if _, ok := object[name]; !ok {
			return false
		}
	}
	return true
}
