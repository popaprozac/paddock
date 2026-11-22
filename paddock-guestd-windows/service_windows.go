package main

import (
	"log"

	"golang.org/x/sys/windows/svc"
)

// isService is whether Windows' service manager started this process.
func isService() bool {
	is, err := svc.IsWindowsService()
	return err == nil && is
}

// runService runs `serve` as the service paddock-guestd until the service manager stops it. If
// serve fails, as when the agent can't listen on vsock yet early in a boot, the service stops with
// an error, and the recovery actions install.ps1 sets start it again, as they do if the agent dies.
//
// shortcut: as a service the agent's log goes nowhere; write it to the Event Log if its messages
// (refused connections, adapter restarts) are needed.
func runService(serve func() error) {
	if err := svc.Run("paddock-guestd", service{serve}); err != nil {
		log.Fatalf("paddock-guestd: can't run as a service: %v", err)
	}
}

type service struct{ serve func() error }

func (s service) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	failed := make(chan error, 1)
	go func() { failed <- s.serve() }()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case err := <-failed:
			log.Print(err)
			return true, 1 // a service-specific exit code, which counts as a failure
		case r := <-requests:
			switch r.Cmd {
			case svc.Interrogate:
				status <- r.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				return false, 0
			}
		}
	}
}
