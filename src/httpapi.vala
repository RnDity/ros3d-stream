errordomain HttpAPIError {
	BAD_REQUEST
}

class HttpAPI : Soup.Server {

	public HttpAPI(int port) {

		add_handler("/version", version_handler);
		add_handler("/info", info_handler);
		add_handler("/alive", alive_handler);
		add_handler("/start", start_handler);
		add_handler("/stop", stop_handler);
	}

	private static void dump_params(GLib.HashTable<string, string>? query) {
		if (query != null) {
			debug("query params:");
			query.foreach((key, val) => {
					debug("  %s: %s", key, val);
				});
		}
	}

	private static void dump_headers(Soup.MessageHeaders headers) {
		debug("heaers:");
		headers.foreach((n, v) => {
				debug("  %s: %s", n, v);
			});
	}

	private static string? client_address(Soup.ClientContext client) {
		var cl_address = client.get_remote_address() as InetSocketAddress;
		if (cl_address != null)
			return cl_address.address.to_string();

		return null;
	}

	private static void not_allowed(Soup.Message msg) {
		msg.set_status(Soup.Status.METHOD_NOT_ALLOWED);
	}

	/**
	 * get_id:
	 * @query: HTTP query parameters
	 * @throws: HttpAPIError if query is incomplete, or client ID was not provided
	 *
	 * Extract client ID from query parameters
	 * @return non-0 client ID
	 */
	private static uint get_id(GLib.HashTable<string, string>? query) throws HttpAPIError {
		if (query == null)
			throw new HttpAPIError.BAD_REQUEST("No query provided");

		if (query.contains("id") == false)
			throw new HttpAPIError.BAD_REQUEST("No client ID");

		var id = (uint) int.parse(query.get("id"));
		if (id == 0)
			throw new HttpAPIError.BAD_REQUEST("Incorrect ID format");

		return id;
	}

	private static void log_request(Soup.Message msg,
									GLib.HashTable<string, string>? query,
									Soup.ClientContext client) {

		if (Config.debug_on == false)
			return;

		debug("dumping request info -->");
		debug("  request: %s", msg.method);
		debug("  URI: %s", msg.uri.to_string(false));
		dump_headers(msg.request_headers);
		dump_params(query);
		debug("<--");
	}

	private static void version_handler (Soup.Server server, Soup.Message msg, string path,
											GLib.HashTable<string, string>? query,
											Soup.ClientContext client) {
		log_request(msg, query, client);

		if (msg.method != "GET") {
			not_allowed(msg);
			return;
		}

		debug("version handler");
		debug("method: %s", msg.method);

		dump_params(query);

		msg.set_response("text/plain", Soup.MemoryUse.STATIC, "0.1".data);
		msg.set_status(Soup.Status.OK);
	}

	private static void info_handler (Soup.Server server, Soup.Message msg, string path,
										GLib.HashTable? query, Soup.ClientContext client) {
		debug("info handler");
		log_request(msg, query, client);


		msg.set_response("text/plain", Soup.MemoryUse.STATIC, "video/x-raw".data);
		msg.set_status(Soup.Status.OK);
	}

	private static void start_handler (Soup.Server server, Soup.Message msg, string path,
									   GLib.HashTable<string, string>? query,
									   Soup.ClientContext client) {
		debug("start handler");
		log_request(msg, query, client);

		string address = null;
		uint16 port = 0;

		try {
			if (query == null) {
				throw new HttpAPIError.BAD_REQUEST("No query parameters");
			} else {
				if (query.contains("port") == false) {
					// missing port
					throw new HttpAPIError.BAD_REQUEST("Port not provided");
				}

				// extract port
				port = (uint16) int.parse(query.get("port"));
				if (port == 0) {
					// bad parse
					throw new HttpAPIError.BAD_REQUEST("Bad port number");
				}

				if (query.contains("client") == true) {
					// client explicitly provided
					address = query.get("client");
				} else {
					// take client from request
					address = client_address(client);
				}
			}
		} catch (HttpAPIError e) {

			msg.set_response("text/plain", Soup.MemoryUse.COPY,
							 "Incorrect request: %s".printf(e.message).data);
			msg.set_status(Soup.Status.BAD_REQUEST);

			return;
		}

		debug("start stream to: %s:%u", address, port);

		var self = server as HttpAPI;
		var id = self.client_start(address, port);

		debug("got ID: %u", id);
		if (id > 0) {
			msg.set_response("text/plain", Soup.MemoryUse.COPY, "%u".printf(id).data);
			msg.set_status(Soup.Status.OK);
		} else {
			msg.set_response("text/plain", Soup.MemoryUse.STATIC,
							 "The stream could not have been started".data);
			msg.set_status(Soup.Status.SERVICE_UNAVAILABLE);
		}
	}

	private static void stop_handler (Soup.Server server, Soup.Message msg, string path,
										GLib.HashTable<string, string>? query,
										Soup.ClientContext client) {
		debug("stop handler");
		log_request(msg, query, client);

		uint id = 0;
		try {
			id = get_id(query);

		} catch (HttpAPIError e) {
			msg.set_response("text/plain", Soup.MemoryUse.COPY,
							 "Incorrect request: %s".printf(e.message).data);
			msg.set_status(Soup.Status.BAD_REQUEST);

			return;
		}

		var self = server as HttpAPI;
		self.client_stop(id);

		msg.set_status(Soup.Status.OK);
	}

	private static void alive_handler (Soup.Server server, Soup.Message msg, string path,
										GLib.HashTable<string, string>? query,
										Soup.ClientContext client) {
		debug("alive handler");
		log_request(msg, query, client);

		uint id = 0;
		try {
			id = get_id(query);

		} catch (HttpAPIError e) {
			msg.set_response("text/plain", Soup.MemoryUse.COPY,
							 "Incorrect request: %s".printf(e.message).data);
			msg.set_status(Soup.Status.BAD_REQUEST);

			return;
		}

		var self = server as HttpAPI;
		self.client_stop(id);

		msg.set_status(Soup.Status.OK);
	}

	/**
	 * client_start:
	 * @host: client host
	 * @port: client port
	 *
	 * Start new client stream. The destination is specified by @host
	 * and @port parameters. The signal handler shall return a client
	 * ID, that shall be used for all subsequent client
	 * requests. Client ID equal to 0 indicates that the stream could
	 * not have been started.
	 *
	 * @return: non-0 assigned client ID.
	 */
	public signal uint client_start(string host, uint port);
	/**
	 * client_stop:
	 * @id: client ID
	 */
	public signal void client_stop(uint id);
	/**
	 * client_ping:
	 * @id: client ID
	 *
	 * Client keepalive request
	 */
	public signal void client_ping(uint id);
}