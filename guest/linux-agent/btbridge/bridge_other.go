//go:build !linux

package btbridge

import (
	"errors"
	"io"
)

func prepare() {}

func attach() (io.ReadWriteCloser, string, error) {
	return nil, "", errors.New("Bluetooth sharing needs a Linux guest")
}
