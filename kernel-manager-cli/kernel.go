package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
)

type Kernel struct {
	Id           string `json:"id"`
	KernelSpec   string `json:"name"`
	LastActivity string `json:"last_activity"`
	Status       string `json:"execution_state"`
	Connections  int    `json:"connections"`
}

func (k Kernel) String() string {
	return fmt.Sprintf("%s (%s)", k.Id, k.KernelSpec)
}

func listKernels(server Server) ([]Kernel, error) {
	resp, err := http.Get(
		fmt.Sprintf("%sapi/kernels?token=%s", server.Url, server.Token),
	)
	if err != nil {
		return nil, err
	}

	var kernels []Kernel
	if err := json.NewDecoder(resp.Body).Decode(&kernels); err != nil {
		return nil, err
	}

	return kernels, nil
}

type StartKernelRequest struct {
	KernelSpec string `json:"name,omitempty"`
	Path       string `json:"path,omitempty"`
}

func startKernel(server Server, kernelspec string, path string) (Kernel, error) {
	payload := StartKernelRequest{KernelSpec: kernelspec, Path: path}

	buf, err := json.Marshal(payload)
	if err != nil {
		return Kernel{}, err
	}

	url := fmt.Sprintf("%sapi/kernels?token=%s", server.Url, server.Token)
	resp, err := http.Post(url, "application/json", bytes.NewReader(buf))
	if err != nil {
		return Kernel{}, err
	}

	var kernel Kernel
	if err := json.NewDecoder(resp.Body).Decode(&kernel); err != nil {
		return Kernel{}, err
	}

	return kernel, nil
}

func stopKernel(server Server, kernelId string) error {
	url := fmt.Sprintf("%sapi/kernels/%s?token=%s", server.Url, kernelId, server.Token)
	req, err := http.NewRequest(http.MethodDelete, url, nil)
	resp, err := http.DefaultClient.Do(req)
	if resp.StatusCode == 404 {
		return fmt.Errorf("Kernel not found: %s", kernelId)
	}

	return err
}

func interruptKernel(server Server, kernelId string) error {
	url := fmt.Sprintf("%sapi/kernels/%s/interrupt?token=%s", server.Url, kernelId, server.Token)
	resp, err := http.Post(url, "", nil)

	if resp.StatusCode == 404 {
		return fmt.Errorf("Kernel not found: %s", kernelId)
	}
	return err
}

func restartKernel(server Server, kernelId string) error {
	url := fmt.Sprintf("%sapi/kernels/%s/restart?token=%s", server.Url, kernelId, server.Token)
	resp, err := http.Post(url, "", nil)

	if resp.StatusCode == 404 {
		return fmt.Errorf("Kernel not found: %s", kernelId)
	}
	return err
}

func listKernelSpecs(server Server) ([]string, error) {
	resp, err := http.Get(
		fmt.Sprintf("%sapi/kernels?token=%s", server.Url, server.Token),
	)
	if err != nil {
		return nil, err
	}

	var kernelspecs []string
	if err := json.NewDecoder(resp.Body).Decode(&kernelspecs); err != nil {
		return nil, err
	}

	return kernelspecs, nil
}
