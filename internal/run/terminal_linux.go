//go:build linux

package run

import (
	"syscall"
	"unsafe"
)

func terminalIsTTY(fd uintptr) bool {
	var termios syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TCGETS, uintptr(unsafe.Pointer(&termios)))
	return errno == 0
}

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
