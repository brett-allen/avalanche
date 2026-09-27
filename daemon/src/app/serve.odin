package main

import "core:fmt"
import "core:log"
import "core:os"
import "avalanche:api"
import "avalanche:session"

run_serve :: proc(opt: Options, rt: Runtime) {
	eng := session.engine_make(rt.listen_port, rt.dht_enabled)
	defer session.engine_destroy(eng)

	api_url := fmt.tprintf("http://%s:%d", rt.api_host, int(rt.api_port))
	log.infof("avalanched starting peer_port=%d api=%s output=%s dht=%v config=%q",
		int(rt.listen_port), api_url, rt.download_dir, rt.dht_enabled,
		rt.config_path if rt.config_path != "" else "(defaults)")

	fmt.printfln("avalanched")
	fmt.printfln("  peer listen  %d", int(rt.listen_port))
	fmt.printfln("  api          %s", api_url)
	fmt.printfln("  output       %s", rt.download_dir)
	fmt.printfln("  dht          %v", rt.dht_enabled)
	if rt.config_path != "" {
		fmt.printfln("  config       %s", rt.config_path)
	}
	fmt.println()
	fmt.println("endpoints:")
	fmt.println("  GET    /health")
	fmt.println("  GET    /api/torrents")
	fmt.println("  GET    /api/torrents/:id")
	fmt.println("  POST   /api/torrents          {\"magnet\":\"...\"} or {\"path\":\"file.torrent\"}")
	fmt.println("  POST   /api/torrents/:id/stop")
	fmt.println("  DELETE /api/torrents/:id")

	err := api.listen_and_serve(eng, api.Server_Config{
		host   = rt.api_addr,
		port   = rt.api_port,
		output = rt.download_dir,
	})
	if err != nil {
		log.errorf("api server stopped: %v", err)
		fmt.eprintfln("%s server stopped: %v", paint(.Err, "error:"), err)
		os.exit(1)
	}
}
