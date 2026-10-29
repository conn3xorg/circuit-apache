# Local example

Applies circuit-apache to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

Three virtual hosts, over plain HTTP: `www.example.test` on `:8080` serves a page from `/srv/www`, `app.example.test` on the same port proxies to `backend.example.test` on `:8081` and adds an `X-Proxied-By` header, and the backend serves a second page from `/srv/backend`. A second circuit in `main.tf` writes the pages and installs curl.

On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To look at the result:

```sh
ssh -p 2281 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 curl -si -H 'Host: app.example.test' localhost:8080
```

`up.sh` listens on `127.0.0.1:2281`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, the key and the state.
