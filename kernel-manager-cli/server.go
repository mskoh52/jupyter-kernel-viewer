package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

type Server struct {
	Hostname string `json:"hostname"`
	Port     int    `json:"port"`
	Token    string `json:"token"`
	RootDir  string `json:"root_dir"`
	Url      string `json:"url"`
	Password bool   `json:"password"`
	Pid      int    `json:"pid"`
	Sock     string `json:"sock"`
}

func (s Server) String() string {
	return fmt.Sprintf(
		"%s (%s)",
		s.Url, s.RootDir,
	)
}

func listServers() ([]Server, error) {
	stdout, err := exec.Command("jupyter", "server", "list", "--json").Output()
	if err != nil {
		return nil, err
	}

	var servers []Server
	lines := strings.Split(strings.TrimRight(string(stdout), "\n"), "\n")
	for _, line := range lines {
		if line == "" {
			continue
		}

		var v Server
		if err := json.Unmarshal([]byte(line), &v); err != nil {
			return nil, err
		}
		servers = append(servers, v)
	}

	return servers, nil
}

func stopServer(servers []Server, selector string) (Server, error) {
	server, err := selectServer(servers, selector)
	if err != nil {
		return Server{}, err
	}

	if err := exec.Command("jupyter", "server", "stop", fmt.Sprintf("%v", server.Port)).Run(); err != nil {
		return Server{}, err
	}
	return server, nil
}

func selectServer(servers []Server, selector string) (Server, error) {
	var candidates []Server
	for _, s := range servers {
		if strings.Contains("^"+s.Url+"$", selector) || strings.Contains("^"+s.RootDir+"$", selector) {
			candidates = append(candidates, s)
		}
	}

	if len(candidates) == 1 {
		return candidates[0], nil
	} else {
		return Server{}, fmt.Errorf("found candidate servers (%s) for search string '%s'", candidates, selector)
	}
}
