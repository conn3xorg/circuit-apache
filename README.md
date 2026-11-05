# circuit-apache

[![Conn3x grade](https://conn3x.org/circuits/apache/grade.svg)](https://conn3x.org/circuits/apache/grade)

A Conn3x circuit that installs the Apache HTTP Server from your distribution's packages and serves the virtual hosts you list: a directory of files on one name, a reverse proxy to an app on another, TLS on a third with certificates you already have.

Apache is the same server on Debian and on Rocky Linux, but it doesn't look it. It's `apache2` on one and `httpd` on the other, with a different service name, a different user, a different tree under `/etc`, and `a2enmod` on one side where the other has `conf.modules.d`. You describe the virtual hosts once and the circuit puts them in the right place on each. Every change shows up in `conn3x plan` as a diff, and the apply runs Apache's own config test before anything goes live, so a typo fails the apply and the running server keeps its old config.

> **On a host that already runs Apache:** the circuit takes over the `Listen` lines and turns off the distribution's default site. Sites you set up by hand keep their files, but only answer on the ports your `vhosts` use. Move them into `vhosts`, or into `extra_config`, before the first apply.

## Usage

```hcl
module "apache" {
  source = "github.com/conn3xorg/circuit-apache?ref=v0.2.0"

  hosts                = { web1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  vhosts = {
    site = {
      server_name   = "example.com"
      aliases       = ["www.example.com"]
      document_root = "/srv/www/example"
    }
    photos = {
      server_name     = "photos.example.com"
      proxy_pass      = "http://127.0.0.1:2283/"
      tls_certificate = "/etc/letsencrypt/live/photos/fullchain.pem"
      tls_key         = "/etc/letsencrypt/live/photos/privkey.pem"
    }
  }

  modules      = ["headers", "rewrite"]
  extra_config = "ServerTokens Prod"
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

A virtual host listens on port 80, or 443 when it has a certificate, unless you give it a `port`. It serves files from `document_root` or proxies everything to `proxy_pass`. For anything those two don't cover, such as a redirect or a `<Location>` block, put Apache directives in `extra` and they go inside the `<VirtualHost>` as written:

```hcl
old = {
  server_name = "old.example.com"
  extra       = "Redirect permanent / https://example.com/"
}
```

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its packages and paths by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.web : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### TLS certificates

The circuit doesn't get certificates. Point `tls_certificate` and `tls_key` at files that are already on the host, such as the ones [circuit-certbot](https://github.com/conn3xorg/circuit-certbot) keeps under `/etc/letsencrypt/live`. Apache's config test fails when a certificate file is missing, so the certificate has to be there before this circuit's apply. With certbot's `"webroot"` method, serve its `webroot_path` as the `document_root` of a port 80 virtual host for the same name, and set certbot's `deploy_hook` to `systemctl reload apache2` on Debian and Ubuntu or `systemctl reload httpd` on the Red Hat family, so renewed certificates are picked up.

## What it does

On each host, in order:

1. Installs `apache2` on Debian and Ubuntu, or `httpd` on Rocky Linux, Fedora and the rest of the Red Hat family, from the distribution's own repositories.
2. Turns on the modules in `modules`, plus `proxy` and `proxy_http` when a virtual host has `proxy_pass` and `ssl` when one has a certificate or proxies to `https://`. On Debian and Ubuntu that's `a2enmod`, which also turns on what each module depends on. On the Red Hat family, where `conf.modules.d` loads most modules already, dnf installs the package that has a module's `.so` when it's missing, such as `mod_ssl`, and the config loads any module that isn't loaded yet.
3. Creates each `document_root` that's missing.
4. Hands the Listen lines to the circuit's config, since Apache refuses to start when two files listen on the same port. On Debian and Ubuntu, `/etc/apache2/ports.conf` becomes a comment, and the `000-default` site is turned off. On the Red Hat family, the `Listen 80` line in `/etc/httpd/conf/httpd.conf` becomes a comment, and when a virtual host uses TLS, `/etc/httpd/conf.d/ssl.conf` keeps mod_ssl's server-wide settings but loses its own Listen line and default virtual host, whose certificate doesn't exist until Apache first starts.
5. On the Red Hat family with SELinux on: lets Apache listen on each port outside SELinux's web ports with `semanage port`, labels each `document_root` that isn't already web content as `httpd_sys_content_t`, and turns on `httpd_can_network_connect` when a virtual host proxies, so Apache can reach a backend on any port.
6. Renders the config to `conn3x.conf.candidate` in `/etc/apache2` or `/etc/httpd`, and adds an include file that loads after the distribution's own config files: `conf-enabled/zz-conn3x.conf` on Debian and Ubuntu, `conf.d/zz-conn3x.conf` on the Red Hat family.
7. Runs Apache's config test with the candidate in place of the live config. If it passes, copies the candidate to `conn3x.conf`. If someone edits the live file by hand, the next apply puts it back.
8. Starts Apache now and at boot, and reloads it gracefully after the config or the modules change, so requests in flight finish on the old config.

The config has a `Listen` line for each port the virtual hosts use, then `extra_config`, then one `<VirtualHost *:PORT>` block per virtual host, in order of their names. Apache answers a request whose name matches none of a port's virtual hosts with the first one on that port, so name them with that in mind. The `config` output shows exactly what the circuit writes.

A `document_root` gets `Require all granted`. A `proxy_pass` becomes `ProxyPass` and `ProxyPassReverse` for `/`, with `ProxyPreserveHost On`, so the app sees the name the client asked for.

Before the circuit runs, the `conn3x_host` data source reads each host's distribution over SSH, which decides the packages and paths.

### What it doesn't do

- Get or renew certificates. See [TLS certificates](#tls-certificates).
- Open firewall ports. Open 80 and 443, or whatever your virtual hosts use, yourself or with [circuit-firewall](https://github.com/conn3xorg/circuit-firewall).
- Put files in a `document_root`. Write them with your own steps, readable by Apache's user: `www-data` on Debian and Ubuntu, `apache` on the Red Hat family.
- Install modules that aren't packaged with Apache on Debian and Ubuntu, such as `libapache2-mod-php`. Install the package first, then name the module in `modules`.
- Turn modules off. Taking one out of `modules` leaves it on.
- Choose the Apache version. You get the one your distribution ships and updates.
- Remove Apache. Deleting the module leaves Apache installed and running with the last config.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `vhosts` | map(object) | Required | Virtual hosts, at least one, by a name of your choosing. Each takes `server_name` and optional `aliases`, a list of more names; `port`, default 80, or 443 with a certificate; `document_root`, an absolute path to serve files from, or `proxy_pass`, an `http://` or `https://` URL to proxy to, but not both; `tls_certificate` and `tls_key`, absolute paths to PEM files, together; and `extra`, further Apache directives for the virtual host. Virtual hosts on the same port all use TLS or none do. |
| `modules` | list(string) | `[]` | Modules to turn on, by name without `mod_`, such as `["headers", "rewrite"]`. `proxy`, `proxy_http` and `ssl` are added when a virtual host needs them. |
| `extra_config` | string | `""` | Further Apache directives for the server as a whole, such as `"ServerTokens Prod"`. They load after the distribution's own config, so they override it. |

## Outputs

| Name | Description |
| --- | --- |
| `config` | The config the circuit writes to `conn3x.conf`: the Listen lines, `extra_config` and the virtual hosts. On the Red Hat family the file also has a `LoadModule` line, inside `<IfModule>`, for each module in `modules`. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, with a package mirror the host can reach.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, fetches a page by its name and by its alias, fetches a second page through a reverse proxy and checks the header the proxy adds, and checks `extra_config` overrides the distribution's `ServerTokens`. The CI containers run with SELinux off.

By hand, on Debian 13 and Rocky Linux 10 containers: a TLS virtual host on 8443 proxying to a second TLS virtual host over `https://` served its page; a misspelled directive in `extra_config` stopped the apply with Apache's error and left the live config and the running server as they were; on Rocky Linux, so did a certificate path that didn't exist; and a hand edit to the live config showed in the next plan and was put back by the apply.

On Ubuntu 24.04 and Rocky Linux 10 droplets (1 vCPU, 1 GB), the example's virtual hosts and the TLS one served their pages, and the second plan had no changes. Rocky Linux ran with SELinux enforcing: Apache ran confined as `httpd_t` on ports 8080, 8081 and 8443, served `/srv/backend` once it was labelled, proxied to 8081, and the audit log had no denials. After a reboot, both came back serving the same pages, with a plan that had no changes.

## License

MPL-2.0. See [LICENSE](LICENSE). The Apache HTTP Server itself is Apache-2.0.
