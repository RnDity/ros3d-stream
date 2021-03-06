/**
 * Copyright (c) 2015 Open-RnD Sp. z o.o.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use, copy,
 * modify, merge, publish, distribute, sublicense, and/or sell copies
 * of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 * BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
 * ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

class StreamManager : Object {

	/**
	 * default client keepalive
	 */
	public const int DEFAULT_KEEPALIVE = 60;

	/**
	 * published service name
	 */
	public const string SERVICE_NAME = "Ros3D Streaming";

	/**
	 * active clients
	 */
	private HashTable<uint, StreamClient> clients;

	/**
	 * stream wrapper
	 */
	private Stream stream = null;

	/**
	 * service publisher
	 */
	private Publisher service_publisher = null;

	/**
	 * client API handle
	 */
	private HttpAPI client_api = null;

	/**
	 * keepalive interval
	 */
	private uint keepalive = DEFAULT_KEEPALIVE;
	private uint keepalive_on = 0;

	public StreamManager(Stream s) {
		this.stream = s;
		this.clients = new HashTable<uint, StreamClient>(direct_hash, direct_equal);
	}

	public void add_client_api(HttpAPI api) {

		client_api = api;

		api.client_start.connect((host, port) => {
				return this.client_start(host, port);
			});
		api.client_stop.connect((id) => {
				this.client_stop(id);
			});
		api.client_ping.connect((id) => {
				this.client_ping(id);
			});

		publish_client_api(api);
	}

	public void set_service_publisher(Publisher pub) {
		debug("set publisher");

		service_publisher = pub;

		publish_client_api(client_api);
	}

	public void set_keepalive_time(uint time) {
		keepalive = time;
	}

	/**
	 * publish_client_api:
	 * @api: client API
	 *
	 * Try publishing client API with service publisher.
	 */
	private void publish_client_api(HttpAPI api) {

		if (service_publisher == null)
			return;

		if (api == null)
			return;

		var ports = api.get_listen_ports();

		ports.foreach((port) => {
				service_publisher.publish(SERVICE_NAME, (uint16) port);

			});
	}

	/**
	 * get_random_id:
	 *
	 * @return: a randomized client id
	 */
	private static uint get_random_id() {
		return (uint) Random.int_range(1, int32.MAX);;
	}

	/**
	 * get_next_id:
	 *
	 * @return: a client ID that does not collide with currently
	 * tracked ones
	 */
	private uint get_next_id() {
		uint id = 0;
		while (true) {
			id = get_random_id();

			if (clients.contains(id) == true)
				debug("client ID collision, try next");
			else
				break;
		}

		debug("new available client ID: %u", id);
		return id;
	}

	/**
	 * client_start:
	 * @host:
	 * @port:
	 *
	 * Start a new client and return assigned ID
	 *
	 * @return non-0 client ID, 0 indicates an error
	 */
	private uint client_start(string host, uint port) {
		debug("start client %s:%u", host, port);

		var id = get_next_id();
		var client = new StreamClient(host, (uint16) port, id);

		debug("starting client: %s", client.to_string());

		if (stream.client_join(client) == false) {
			warning("failed to start streaming to client %s:%u",
					host, port);
			// indicate an error
			return 0;
		}

		clients.insert(id, client);

		start_keepalive_check();
		return id;
	}


	/**
	 * client_stop:
	 * @id:
	 *
	 * Stop the stream for given client ID
	 */
	private void client_stop(uint id) {
		debug("stop client %u", id);

		if (clients.contains(id) == false) {
			warning("client %u not found", id);
			return;
		}

		var client = clients.get(id);

		debug("stopping client: %s", client.to_string());

		clients.remove(id);

		stream.client_leave(client);
	}

	/**
	 * client_ping:
	 * @id:
	 *
	 * Keepalive request for given client
	 */
	private void client_ping(uint id) {
		debug("ping from client %u", id);

		var client = clients.get(id);

		if (client != null)
			client.refresh();
	}

	/**
	 * start_keepalive_check:
	 */
	private void start_keepalive_check() {
		if (keepalive_on == 0) {
			debug("starting keepalive check, check every %u seconds",
				  keepalive);
			keepalive_on = Timeout.add_seconds(keepalive,
											   this.on_keepalive_check);
		}
	}

	/**
	 * stop_keeaplive_check:
	 */
	private void stop_keeaplive_check() {
		if (keepalive_on != 0) {
			Source.remove(keepalive_on);
			keepalive_on = 0;
		}
	}

	/**
	 * on_keepalive_check:
	 *
	 * @return true if keepalive checking should continue
	 */
	private bool on_keepalive_check() {
		check_stale_clients();

		if (clients.size() == 0) {
			stop_keeaplive_check();
			return false;
		}

		return true;
	}

	/**
	 * check_stale_clients:
	 *
	 * Check if stale clients exists and remove them
	 */
	private void check_stale_clients() {
		// go through all clients and check their age, if above
		// keepalive, then stop the stream and remove the client
		clients.foreach_remove((k, cl) => {
				var age = cl.age();
				debug("checking client %s of age: %s",
					  cl.to_string(), age.to_string());

				if (age > keepalive) {
					warning("removing stale client: %s", cl.to_string());

					// stop client stream
					stream.client_leave(cl);
					return true;
				}

				return false;
			});
	}

}
