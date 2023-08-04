package utils

import "os"

func Exists(filepath string) bool {
	_, err := os.Stat(filepath)
	return err == nil
}

func EnsureDir(dirname string) error {
	if !Exists(dirname) {
		return os.MkdirAll(dirname, 0700)
	}
	return nil
}
