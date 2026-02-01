/*
Copyright 2016 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"fmt"
	"os"
	"syscall"

	"github.com/alibaba/higress/api-server/pkg/cmd/server"
	genericapiserver "k8s.io/apiserver/pkg/server"
	"k8s.io/component-base/cli"
)

func init() {
	// Increase file descriptor limit early to avoid "too many open files" errors
	var rLimit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &rLimit); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to get rlimit: %v\n", err)
		return
	}

	fmt.Printf("Current file descriptor limit: soft=%d hard=%d\n", rLimit.Cur, rLimit.Max)

	// Try to set soft limit to 65535
	targetLimit := uint64(65535)
	if rLimit.Cur < targetLimit {
		rLimit.Cur = targetLimit
		// If hard limit is less than target, try to increase it (may require root)
		if rLimit.Max < targetLimit {
			rLimit.Max = targetLimit
		}

		if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &rLimit); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to set rlimit to %d: %v\n", targetLimit, err)
			return
		}

		fmt.Printf("Updated file descriptor limit: soft=%d hard=%d\n", rLimit.Cur, rLimit.Max)
	}
}

func main() {
	stopCh := genericapiserver.SetupSignalHandler()
	options := server.NewHigressServerOptions(os.Stdout, os.Stderr)
	cmd := server.NewCommandStartHigressServer(options, stopCh)
	code := cli.Run(cmd)
	os.Exit(code)
}
