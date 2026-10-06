package run

import (
	"context"
	"errors"
)

var ErrProvider = errors.New("workspace credential retrieval failed; check provider authorization and configuration")

type Provider interface {
	Resolve(context.Context, Selection) (Profile, error)
}
