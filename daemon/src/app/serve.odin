package main

import "core:fmt"
import "core:net"
import "core:os"
import "avalanche:api"
import "avalanche:session"

run_serve :: proc(opt: Options) {
	out := opt.output if opt.output != "" else "downloads"
	api_port := opt.api_port if opt.api_port != 0 else api.DEFAULT_API_PORT
	bt_port := listen_port(opt)

	eng := session.engine_make(bt_port)
	defer session.engine_destroy(eng)

	fmt.printfln("avalanched")
	fmt.printfln("  peer listen  %d", int(bt_port))
	fmt.printfln("  api          http://127.0.0.1:%d", int(api_port))
	fmt.printfln("  output       %s", out)
	fmt.println()
	fmt.println("endpoints:")
	fmt.println("  GET    /health")
	fmt.println("  GET    /api/torrents")
	fmt.println("  GET    /api/torrents/:id")
	fmt.println("  POST   /api/torrents          {\"magnet\":\"...\"} or {\"path\":\"file.torrent\"}")
	fmt.println("  POST   /api/torrents/:id/stop")
	fmt.println("  DELETE /api/torrents/:id")

	err := api.listen_and_serve(eng, api.Server_Config{
		host   = net.IP4_Loopback,
		port   = api_port,
		output = out,
	})
	if err != nil {
		fmt.eprintfln("%s server stopped: %v", paint(.Err, "error:"), err)
		os.exit(1)
	}
}
