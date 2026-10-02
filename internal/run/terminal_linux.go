//go:build linux

package run

import (
	"syscall"
	"unsafe"
)

func terminalForeground(fd uintptr) (int, error) {
	var termios syscall.Termios
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TCGETS, uintptr(unsafe.Pointer(&termios))); errno != 0 {
		return 0, errno
	}
	var pgrp int32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCGPGRP, uintptr(unsafe.Pointer(&pgrp))); errno != 0 {
		return 0, errno
	}
	return int(pgrp), nil
}

func setTerminalForeground(fd uintptr, pgrp int) error {
	value := int32(pgrp)
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCSPGRP, uintptr(unsafe.Pointer(&value)))
	if errno != 0 {
		return errno
	}
	return nil
}
