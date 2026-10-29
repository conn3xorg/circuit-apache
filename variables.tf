variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "vhosts" {
  type = map(object({
    server_name     = string
    aliases         = optional(list(string), [])
    port            = optional(number)
    document_root   = optional(string)
    proxy_pass      = optional(string)
    tls_certificate = optional(string)
    tls_key         = optional(string)
    extra           = optional(string, "")
  }))
  description = "Virtual hosts, by a name of your choosing. Each answers for server_name and aliases on port, and serves files from document_root or proxies to proxy_pass, with TLS when tls_certificate and tls_key are set."

  validation {
    condition     = length(var.vhosts) > 0
    error_message = "vhosts needs at least one virtual host. Apache listens only on the ports its virtual hosts use."
  }

  validation {
    condition     = alltrue([for v in values(var.vhosts) : alltrue([for n in concat([v.server_name], v.aliases) : can(regex("^[A-Za-z0-9*?_.:\\[\\]-]+$", n))])])
    error_message = "server_name and each alias must be a host name such as \"example.com\" or \"*.example.com\", without spaces."
  }

  validation {
    condition     = alltrue([for v in values(var.vhosts) : v.port == null || try(v.port >= 1 && v.port <= 65535 && floor(v.port) == v.port, false)])
    error_message = "A virtual host's port must be a port number from 1 to 65535."
  }

  validation {
    condition     = alltrue([for v in values(var.vhosts) : v.document_root == null || v.proxy_pass == null])
    error_message = "A virtual host takes document_root or proxy_pass, not both. Put a more involved one together in extra."
  }

  validation {
    condition     = alltrue([for v in values(var.vhosts) : alltrue([for p in compact([v.document_root, v.tls_certificate, v.tls_key]) : can(regex("^/[^\"\\n]*$", p))])])
    error_message = "document_root, tls_certificate and tls_key must be absolute paths, such as \"/srv/www\", without double quotes."
  }

  validation {
    condition     = alltrue([for v in values(var.vhosts) : v.proxy_pass == null || can(regex("^https?://[^\\s\"]+$", coalesce(v.proxy_pass, "-")))])
    error_message = "proxy_pass must be an http:// or https:// URL, such as \"http://127.0.0.1:3000/\"."
  }

  validation {
    condition     = alltrue([for v in values(var.vhosts) : (v.tls_certificate == null) == (v.tls_key == null)])
    error_message = "A virtual host with TLS needs both tls_certificate and tls_key."
  }

  # Apache sets TLS per listening port, so one port can't serve both.
  validation {
    condition = length(distinct([for v in values(var.vhosts) : "${coalesce(v.port, v.tls_certificate != null ? 443 : 80)}"])) == length(distinct([
      for v in values(var.vhosts) : "${coalesce(v.port, v.tls_certificate != null ? 443 : 80)}/${v.tls_certificate != null}"
    ]))
    error_message = "Virtual hosts on the same port must all use TLS or all not use it."
  }
}

variable "modules" {
  type        = list(string)
  default     = []
  description = "Apache modules to turn on, by name without mod_, such as [\"headers\", \"rewrite\"]. proxy, proxy_http and ssl are added when a virtual host needs them."

  validation {
    condition     = alltrue([for m in var.modules : can(regex("^[a-z0-9_]+$", m))])
    error_message = "Each module is a name such as \"rewrite\" or \"proxy_wstunnel\", without mod_ or .so."
  }
}

variable "extra_config" {
  type        = string
  default     = ""
  description = "Further Apache directives for the server as a whole, written before the virtual hosts."
}
