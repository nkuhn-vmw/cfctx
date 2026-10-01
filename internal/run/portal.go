package run

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
)

var ErrProvider = errors.New("workspace credential retrieval failed; check provider authorization and configuration")

type Provider interface {
	Resolve(context.Context, Selection) (Profile, error)
}
type Portal struct{ Context string }

func CleanEnvironmentForPortal() []string {
	env := CleanEnvironment(os.Environ())
	return env
}
func (p Portal) Resolve(ctx context.Context, s Selection) (Profile, error) {
	var result Profile
	path, err := s.Path()
	if err != nil || p.Context == "" || strings.HasPrefix(p.Context, "-") {
		return result, ErrInvalid
	}
	// Keep klportal's own device SSO context but remove environment-token override.
	env := []string{}
	for _, v := range CleanEnvironmentForPortal() {
		env = append(env, v)
	}
	data, err := capture(ctx, env, "klportal", "--ctx", p.Context, "--json", "secret", "get", path, "--workspace", s.Workspace)
	if err != nil {
		return result, ErrProvider
	}
	var detail struct {
		Name  string          `json:"name"`
		Type  string          `json:"type"`
		Value json.RawMessage `json:"value"`
	}
	if json.Unmarshal(data, &detail) != nil || detail.Name != path || detail.Type != "json" {
		return result, ErrProvider
	}
	value := []byte(detail.Value)
	if len(value) > 0 && value[0] == '"' {
		var text string
		if json.Unmarshal(value, &text) != nil {
			return result, ErrProvider
		}
		value = []byte(text)
	}
	if DecodeStrict(value, &result) != nil {
		return result, ErrProvider
	}
	return result, nil
}
