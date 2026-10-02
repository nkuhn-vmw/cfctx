package run

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"reflect"
	"regexp"
	"strings"
)

var ErrInvalid = errors.New("invalid workspace credential configuration")
var selector = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*$`)
var uuid = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

const MaxBytes = 1024 * 1024

type Selection struct{ Workspace, Foundation, Capability string }
type CFTarget struct {
	API       string `json:"api"`
	OrgGUID   string `json:"orgGuid"`
	SpaceGUID string `json:"spaceGuid"`
}
type BOSHTarget struct {
	Endpoint     string `json:"endpoint"`
	DirectorUUID string `json:"directorUuid"`
	Team         string `json:"team"`
}
type Targets struct {
	CF   *CFTarget   `json:"cf,omitempty"`
	BOSH *BOSHTarget `json:"bosh,omitempty"`
}
type Profile struct {
	Version     int               `json:"version"`
	Workspace   string            `json:"workspace"`
	Foundation  string            `json:"foundation"`
	Capability  string            `json:"capability"`
	Targets     Targets           `json:"targets"`
	Credentials map[string]string `json:"credentials"`
}
type Descriptor struct {
	Version          int      `json:"version"`
	Workspace        string   `json:"workspace"`
	Foundation       string   `json:"foundation"`
	Capability       string   `json:"capability"`
	Namespace        string   `json:"namespace"`
	Targets          Targets  `json:"targets"`
	CredentialFields []string `json:"credentialFields"`
	MCPEndpoint      string   `json:"mcpEndpoint,omitempty"`
}

// DecodeStrict rejects unknown fields, duplicate keys and trailing JSON.
func DecodeStrict(data []byte, result any) error {
	if len(data) > MaxBytes || !json.Valid(data) {
		return ErrInvalid
	}
	check := json.NewDecoder(bytes.NewReader(data))
	var walk func() error
	walk = func() error {
		tok, err := check.Token()
		if err != nil {
			return ErrInvalid
		}
		switch tok {
		case json.Delim('{'):
			seen := map[string]bool{}
			for check.More() {
				k, err := check.Token()
				if err != nil {
					return ErrInvalid
				}
				key, ok := k.(string)
				if !ok || seen[key] {
					return ErrInvalid
				}
				seen[key] = true
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = check.Token()
			return err
		case json.Delim('['):
			for check.More() {
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = check.Token()
			return err
		}
		return nil
	}
	if err := walk(); err != nil {
		return ErrInvalid
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(result); err != nil {
		return ErrInvalid
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return ErrInvalid
	}
	return nil
}
func (s Selection) Path() (string, error) {
	for _, v := range []string{s.Workspace, s.Foundation, s.Capability} {
		if len(v) > 63 || !selector.MatchString(v) {
			return "", ErrInvalid
		}
	}
	return "/kuhn-labs/ws/" + s.Workspace + "/contexts/" + s.Foundation + "/" + s.Capability + "/config", nil
}
func httpsEndpoint(s string) bool {
	u, err := url.Parse(s)
	return err == nil && u.Scheme == "https" && u.Hostname() != "" && u.User == nil && u.RawQuery == "" && u.Fragment == "" && u.RawPath == "" && (u.Path == "" || u.Path == "/")
}
func (d Descriptor) Validate(s Selection) error {
	path, err := s.Path()
	if err != nil {
		return err
	}
	if d.Version != 1 || d.Workspace != s.Workspace || d.Foundation != s.Foundation || d.Capability != s.Capability || d.Namespace != strings.TrimSuffix(path, "/config") {
		return ErrInvalid
	}
	if d.Targets.CF == nil && d.Targets.BOSH == nil {
		return ErrInvalid
	}
	if t := d.Targets.CF; t != nil && (!httpsEndpoint(t.API) || !uuid.MatchString(t.OrgGUID) || !uuid.MatchString(t.SpaceGUID)) {
		return ErrInvalid
	}
	if t := d.Targets.BOSH; t != nil && (!httpsEndpoint(t.Endpoint) || !uuid.MatchString(t.DirectorUUID) || !selector.MatchString(t.Team)) {
		return ErrInvalid
	}
	expected := map[string]bool{}
	if d.Targets.CF != nil {
		expected["CF_USERNAME"] = true
		expected["CF_PASSWORD"] = true
	}
	if d.Targets.BOSH != nil {
		expected["BOSH_CLIENT"] = true
		expected["BOSH_CLIENT_SECRET"] = true
		expected["BOSH_CA_CERT"] = true
	}
	if len(d.CredentialFields) != len(expected) {
		return ErrInvalid
	}
	for _, key := range d.CredentialFields {
		if !expected[key] {
			return ErrInvalid
		}
		delete(expected, key)
	}
	return nil
}
func Validate(p Profile, d Descriptor, s Selection) error {
	if err := d.Validate(s); err != nil {
		return err
	}
	if p.Version != 1 || p.Workspace != s.Workspace || p.Foundation != s.Foundation || p.Capability != s.Capability || !reflect.DeepEqual(p.Targets, d.Targets) || len(p.Credentials) != len(d.CredentialFields) {
		return ErrInvalid
	}
	for _, key := range d.CredentialFields {
		v, ok := p.Credentials[key]
		if !ok || v == "" || strings.ContainsRune(v, 0) {
			return ErrInvalid
		}
	}
	return nil
}
func LoadDescriptor(path string) (Descriptor, error) {
	var d Descriptor
	// Configuration is operator-reviewed, regular-file input; no symlink to secrets.
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return d, ErrInvalid
	}
	if info.Size() > MaxBytes {
		return d, ErrInvalid
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return d, ErrInvalid
	}
	return d, DecodeStrict(data, &d)
}
