package main

import (
	"fmt"
	"log"
	"os"

	"github.com/spf13/cobra"
)

func makeServerSubcommand() *cobra.Command {
	serverCmd := &cobra.Command{
		Use:   "server",
		Short: "Manage Jupyter servers",
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List running Jupyter servers",
		Long: `List all locally running Jupyter servers, one per line, in the form:

    <URL>?token=<TOKEN> :: <ROOT_DIR>`,
		Run: func(cmd *cobra.Command, args []string) {
			servers, err := listServers()
			if err != nil {
				log.Fatal(err)
			}

			for _, s := range servers {
				fmt.Printf("%s?token=%s :: %s\n", s.Url, s.Token, s.RootDir)
			}
		},
	}

	stopCmd := &cobra.Command{
		Use:   "stop <selector>",
		Short: "Stop a running server",
		Long: `Stop a running Jupyter server.

The selector is matched as a case-sensitive substring against each server's
URL and root directory. Use ^ to anchor to the start or $ to anchor to the
end of either field. The match must be unique.`,
		Args: cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			servers, err := listServers()
			if err != nil {
				log.Fatal(err)
			}

			server, err := stopServer(servers, args[0])
			if err != nil {
				log.Fatal(err)
			}
			log.Printf("stopping server %v", server)
		},
	}

	serverCmd.AddCommand(listCmd)
	serverCmd.AddCommand(stopCmd)
	return serverCmd
}

func makeKernelSubcommand(servers []Server) *cobra.Command {
	kernelCmd := &cobra.Command{
		Use:   "kernel",
		Short: "Manage kernels on a Jupyter server",
	}
	var selector string
	kernelCmd.PersistentFlags().StringVarP(&selector, "server", "s", "",
		"Select server by substring of URL or root directory; ^ and $ anchor to start/end")

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List kernels running on the server",
		Run: func(cmd *cobra.Command, args []string) {
			server, err := selectServer(servers, selector)
			if err != nil {
				log.Fatal(err)
			}

			kernels, err := listKernels(server)
			if err != nil {
				log.Fatal(err)
			}
			for _, k := range kernels {
				fmt.Println(k)
			}
		},
	}
	kernelCmd.AddCommand(listCmd)

	startCmd := &cobra.Command{
		Use:   "start [kernel_spec] [path]",
		Short: "Start a new kernel",
		Long: `Start a new kernel on the selected server.

  kernel_spec  Name of the kernel spec (default: server default, usually python3)
  path         Working directory for the kernel`,
		Args: cobra.MaximumNArgs(2),
		Run: func(cmd *cobra.Command, args []string) {
			kernelSpec := ""
			if len(args) > 0 {
				kernelSpec = args[0]
			}
			path := ""
			if len(args) > 1 {
				path = args[1]
			}

			server, err := selectServer(servers, selector)
			if err != nil {
				log.Fatal(err)
			}

			kernel, err := startKernel(server, kernelSpec, path)
			if err != nil {
				kernelSpecs, _ := listKernelSpecs(server)
				log.Fatal("could not find kernel spec %s in %v", kernelSpec, kernelSpecs)
			}
			fmt.Printf("startd kernel %v\n", kernel)
		},
	}
	kernelCmd.AddCommand(startCmd)

	stopCmd := &cobra.Command{
		Use:   "stop <kernel_id>",
		Short: "Stop a kernel",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			kernelId := args[0]
			server, err := selectServer(servers, selector)
			if err != nil {
				log.Fatal(err)
			}

			stopKernel(server, kernelId)
		},
	}
	kernelCmd.AddCommand(stopCmd)

	interruptCmd := &cobra.Command{
		Use:   "interrupt <kernel_id>",
		Short: "Send an interrupt signal to a running kernel",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			kernelId := args[0]
			server, err := selectServer(servers, selector)
			if err != nil {
				log.Fatal(err)
			}

			interruptKernel(server, kernelId)
		},
	}
	kernelCmd.AddCommand(interruptCmd)

	restartCmd := &cobra.Command{
		Use:   "restart <kernel_id>",
		Short: "Restart a kernel",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			kernelId := args[0]
			server, err := selectServer(servers, selector)
			if err != nil {
				log.Fatal(err)
			}

			restartKernel(server, kernelId)
		},
	}
	kernelCmd.AddCommand(restartCmd)

	return kernelCmd
}

func main() {
	root := &cobra.Command{
		Use:   "jkm",
		Short: "Manage Jupyter servers and kernels",
		Long: `Manage local Jupyter servers and the kernels running on them.

jkm discovers running servers via "jupyter server list" and exposes operations
on their REST API. It does not start servers — use "jupyter server" for that.`,
	}

	servers, err := listServers()
	if err != nil {
		log.Fatal(err)
	}

	root.AddCommand(makeServerSubcommand())
	root.AddCommand(makeKernelSubcommand(servers))
	root.CompletionOptions.DisableDefaultCmd = true

	if err := root.Execute(); err != nil {
		os.Exit(1)
	}
}
