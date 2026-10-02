package run

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

var ErrCommand = errors.New("workspace authentication or target verification failed")

func CleanEnvironment(env []string) []string {
	out := []string{}
	for _, item := range env {
		key, _, _ := strings.Cut(item, "=")
		remove := key == "VCAP_SERVICES"
		for _, prefix := range []string{"CF_", "BOSH_", "OM_", "UAA_", "CREDHUB_", "CFCTX_", "KLPORTAL_"} {
			remove = remove || strings.HasPrefix(key, prefix)
		}
		if !remove {
			out = append(out, item)
		}
	}
	return out
}

type boundedBuffer struct {
	data     []byte
	overflow bool
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	remaining := MaxBytes - len(b.data)
	if len(p) > remaining {
		b.overflow = true
		p = p[:remaining]
	}
	b.data = append(b.data, p...)
	return n, nil
}
func process(ctx context.Context, env []string, name string, foregroundFD int, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env
	if foregroundFD >= 0 {
		cmd.SysProcAttr = &syscall.SysProcAttr{Foreground: true, Ctty: foregroundFD}
	} else {
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if err == syscall.ESRCH {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.WaitDelay = 3 * time.Second
	return cmd
}
func capture(ctx context.Context, env []string, name string, args ...string) ([]byte, error) {
	cmd := process(ctx, env, name, -1, args...)
	var out boundedBuffer
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil || out.overflow {
		return nil, ErrCommand
	}
	return out.data, nil
}
func prepare(ctx context.Context, p Profile, root string) ([]string, error) {
	env := CleanEnvironment(os.Environ())
	env = append(env, "CF_HOME="+root, "BOSH_CONFIG="+filepath.Join(root, "bosh-config"), "BOSH_NON_INTERACTIVE=true")
	for k, v := range p.Credentials {
		env = append(env, k+"="+v)
	}
	if t := p.Targets.CF; t != nil {
		api := strings.TrimSuffix(t.API, "/")
		if _, err := capture(ctx, env, "cf", "api", api); err != nil {
			return nil, err
		}
		if _, err := capture(ctx, env, "cf", "auth", "--origin", "uaa"); err != nil {
			return nil, err
		}
		orgData, err := capture(ctx, env, "cf", "curl", "/v3/organizations/"+t.OrgGUID)
		if err != nil {
			return nil, err
		}
		var org struct {
			GUID string `json:"guid"`
			Name string `json:"name"`
		}
		if json.Unmarshal(orgData, &org) != nil || org.GUID != t.OrgGUID || org.Name == "" {
			return nil, ErrCommand
		}
		spaceData, err := capture(ctx, env, "cf", "curl", "/v3/spaces/"+t.SpaceGUID)
		if err != nil {
			return nil, err
		}
		var space struct {
			GUID          string `json:"guid"`
			Name          string `json:"name"`
			Relationships struct {
				Organization struct {
					Data struct {
						GUID string `json:"guid"`
					} `json:"data"`
				} `json:"organization"`
			} `json:"relationships"`
		}
		if json.Unmarshal(spaceData, &space) != nil || space.GUID != t.SpaceGUID || space.Name == "" || space.Relationships.Organization.Data.GUID != t.OrgGUID {
			return nil, ErrCommand
		}
		if _, err := capture(ctx, env, "cf", "target", "-o", org.Name, "-s", space.Name); err != nil {
			return nil, err
		}
		data, err := os.ReadFile(filepath.Join(root, ".cf", "config.json"))
		if err != nil {
			return nil, ErrCommand
		}
		var config struct {
			Target             string
			OrganizationFields struct{ GUID string }
			SpaceFields        struct{ GUID string }
			SSLDisabled        bool
		}
		if json.Unmarshal(data, &config) != nil || strings.TrimSuffix(config.Target, "/") != api || config.OrganizationFields.GUID != t.OrgGUID || config.SpaceFields.GUID != t.SpaceGUID || config.SSLDisabled {
			return nil, ErrCommand
		}
	}
	if t := p.Targets.BOSH; t != nil {
		env = append(env, "BOSH_ENVIRONMENT="+t.Endpoint)
		data, err := capture(ctx, env, "bosh", "curl", "/info")
		if err != nil {
			return nil, err
		}
		var info struct {
			UUID string `json:"uuid"`
		}
		if json.Unmarshal(data, &info) != nil || info.UUID != t.DirectorUUID {
			return nil, ErrCommand
		}
	}
	return env, nil
}

// Execute verifies every configured target before launching the child. Child
// permissions are target-side roles; this is not an arbitrary-shell sandbox.
func Execute(ctx context.Context, p Profile, d Descriptor, s Selection, args []string, in io.Reader, out, errOut io.Writer) (int, error) {
	if err := Validate(p, d, s); err != nil {
		return 1, err
	}
	if len(args) == 0 {
		return 1, ErrInvalid
	}
	root, err := os.MkdirTemp("", "cfctx-run-")
	if err != nil {
		return 1, ErrCommand
	}
	defer os.RemoveAll(root)
	setup, cancel := context.WithTimeout(ctx, 60*time.Second)
	env, err := prepare(setup, p, root)
	cancel()
	if err != nil {
		return 1, err
	}
	// CF uses its isolated token file after login; the password is no longer needed.
	childEnv := []string{}
	for _, v := range env {
		if !strings.HasPrefix(v, "CF_USERNAME=") && !strings.HasPrefix(v, "CF_PASSWORD=") {
			childEnv = append(childEnv, v)
		}
	}
	foregroundFD := -1
	var terminalPgrp int
	if file, ok := in.(*os.File); ok {
		if pgrp, ttyErr := terminalForeground(file.Fd()); ttyErr == nil {
			foregroundFD = int(file.Fd())
			terminalPgrp = pgrp
		}
	}
	cmd := process(ctx, childEnv, args[0], foregroundFD, args[1:]...)
	cmd.Stdin = in
	cmd.Stdout = out
	cmd.Stderr = errOut
	err = cmd.Start()
	if err == nil {
		if waitErr := cmd.Wait(); waitErr != nil {
			err = waitErr
		}
	}
	if foregroundFD >= 0 {
		// The command temporarily owns the terminal foreground group. Restore
		// the caller's group while SIGTTOU is ignored, as shells do internally.
		signal.Ignore(syscall.SIGTTOU)
		restoreErr := setTerminalForeground(uintptr(foregroundFD), terminalPgrp)
		signal.Reset(syscall.SIGTTOU)
		if err == nil && restoreErr != nil {
			err = restoreErr
		}
	}
	if ctx.Err() != nil {
		return 130, nil
	}
	if err == nil {
		return 0, nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		code := exit.ExitCode()
		if code < 0 {
			code = 128 + int(exit.Sys().(syscall.WaitStatus).Signal())
		}
		return code, nil
	}
	return 1, errors.New("workspace child command could not start")
}
