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
		Short: "Manage servers",
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "list servers",
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
		Use:   "stop [server]",
		Short: "stop a server, identified with a substring of url or root_dir",
		Args:  cobra.ExactArgs(1),
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
		Short: "Manage kernels",
	}
	var selector string
	kernelCmd.PersistentFlags().StringVarP(&selector, "server", "s", "", "server selector")

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "list kernels",
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
		Use:   "start",
		Short: "start a kernel",
		Args:  cobra.MaximumNArgs(2),
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
		Use:   "stop",
		Short: "stop a kernel",
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
		Use:   "interrupt",
		Short: "interrupt a kernel",
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
		Use:   "restart",
		Short: "restart a kernel",
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
		Short: "Jupyter Kernel Manager",
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
