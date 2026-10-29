variable "port" {
  type    = number
  default = 2281
}

module "apache" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # Two names on :8080: www serves a page from /srv/www, and app proxies to
  # the backend on :8081, which serves another page from /srv/backend.
  vhosts = {
    app = {
      server_name = "app.example.test"
      port        = 8080
      proxy_pass  = "http://127.0.0.1:8081/"
      extra       = "Header set X-Proxied-By apache"
    }
    backend = {
      server_name   = "backend.example.test"
      port          = 8081
      document_root = "/srv/backend"
    }
    www = {
      server_name   = "www.example.test"
      aliases       = ["example.test"]
      port          = 8080
      document_root = "/srv/www"
    }
  }

  modules      = ["headers"]
  extra_config = "ServerTokens Prod"
}

# A page for each document root, and curl to fetch them with. It runs after
# the module, so its package run doesn't overlap the module's.
circuit "content" {
  hosts = { box = "127.0.0.1" }

  ssh {
    user             = "root"
    port             = var.port
    private_key_file = "./id_ed25519"
    known_hosts_file = "./known_hosts"
  }

  step "curl" {
    package {
      name = "curl"
    }
    depends_on = [module.apache]
  }

  step "page" {
    for_each = { www = "Hello from Apache.\n", backend = "Hello from the backend.\n" }
    file {
      path    = "/srv/${item.key}/index.html"
      content = item.value
    }
  }
}
