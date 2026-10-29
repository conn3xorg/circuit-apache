# Facts give each host's distribution: Debian and Ubuntu package Apache as
# apache2, the Red Hat family as httpd, with a different layout under /etc.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  deb_hosts = { for name, h in var.hosts : name => h if local.family[name] == "debian" }
  rpm_hosts = { for name, h in var.hosts : name => h if local.family[name] == "redhat" }

  # The include file is the circuit's only file in the distribution's own
  # include directory, named to load last so extra_config overrides the
  # distribution's defaults, such as ServerTokens on Debian. It reads the
  # live config, or the candidate when Apache runs with -D conn3x_candidate,
  # so the candidate is checked with the rest of the server's config
  # without touching the live one.
  layout = {
    debian = { package = "apache2", service = "apache2", dir = "/etc/apache2", include = "/etc/apache2/conf-available/zz-conn3x.conf", ctl = "apache2ctl" }
    redhat = { package = "httpd", service = "httpd", dir = "/etc/httpd", include = "/etc/httpd/conf.d/zz-conn3x.conf", ctl = "httpd" }
  }
  l = { for name, f in local.family : name => local.layout[f] }

  need_proxy = anytrue([for v in values(var.vhosts) : v.proxy_pass != null])
  need_ssl   = anytrue([for v in values(var.vhosts) : v.tls_certificate != null || startswith(coalesce(v.proxy_pass, "-"), "https:")])
  modules    = distinct(concat(var.modules, local.need_proxy ? ["proxy", "proxy_http"] : [], local.need_ssl ? ["ssl"] : []))

  port      = { for k, v in var.vhosts : k => coalesce(v.port, v.tls_certificate != null ? 443 : 80) }
  ports     = distinct(values(local.port))
  tls_ports = distinct([for k, v in var.vhosts : local.port[k] if v.tls_certificate != null])
  roots     = toset(compact([for v in values(var.vhosts) : v.document_root]))

  # SELinux lets Apache listen on these ports out of the box.
  selinux_ports = [for p in local.ports : p if !contains([80, 81, 443, 488, 8008, 8009, 8443, 9000], p)]

  config_head = join("\n", concat(
    ["# Written by Conn3x. Changes here are overwritten on the next apply."],
    [for p in local.ports : "Listen ${p}${contains(local.tls_ports, p) ? " https" : ""}"],
    [""],
  ))

  config_body = join("\n", concat(
    trimspace(var.extra_config) == "" ? [] : ["${chomp(var.extra_config)}\n"],
    [for k, v in var.vhosts : "${join("\n", concat(
      ["<VirtualHost *:${local.port[k]}>", "    ServerName ${v.server_name}"],
      length(v.aliases) > 0 ? ["    ServerAlias ${join(" ", v.aliases)}"] : [],
      v.document_root == null ? [] : [
        "    DocumentRoot \"${v.document_root}\"",
        "    <Directory \"${v.document_root}\">",
        "        Require all granted",
        "    </Directory>",
      ],
      v.proxy_pass == null ? [] : concat(
        startswith(v.proxy_pass, "https:") ? ["    SSLProxyEngine on"] : [],
        [
          "    ProxyPreserveHost On",
          "    ProxyPass / \"${trimsuffix(v.proxy_pass, "/")}/\"",
          "    ProxyPassReverse / \"${trimsuffix(v.proxy_pass, "/")}/\"",
        ],
      ),
      v.tls_certificate == null ? [] : [
        "    SSLEngine on",
        "    SSLCertificateFile \"${v.tls_certificate}\"",
        "    SSLCertificateKeyFile \"${v.tls_key}\"",
      ],
      [for line in compact(split("\n", chomp(v.extra))) : "    ${line}"],
      ["</VirtualHost>"],
    ))}\n"],
  ))

  # The Red Hat family loads most modules from conf.modules.d already.
  # These lines load the rest, once the modules step has installed them.
  rpm_load = join("", [for m in local.modules : "<IfModule !${m}_module>\n    LoadModule ${m}_module modules/mod_${m}.so\n</IfModule>\n"])

  config   = "${local.config_head}\n${local.config_body}"
  rendered = { for name, f in local.family : name => f == "redhat" && length(local.modules) > 0 ? "${local.config_head}\n${local.rpm_load}\n${local.config_body}" : local.config }

  # Debian turns modules on with a2enmod, which also turns on what they
  # depend on. On the Red Hat family, a module's .so can come from its own
  # package, such as mod_ssl, which dnf finds by the file.
  modules_cmd = {
    debian = { command = "a2enmod -q ${join(" ", local.modules)}", unless = join(" && ", [for m in local.modules : "test -e /etc/apache2/mods-enabled/${m}.load"]) }
    redhat = { command = "dnf -y install ${join(" ", [for m in local.modules : "/usr/lib64/httpd/modules/mod_${m}.so"])}", unless = join(" && ", [for m in local.modules : "test -e /usr/lib64/httpd/modules/mod_${m}.so"]) }
  }
}

circuit "apache" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "package" {
    package {
      name = local.l[each.key].package
    }
  }

  step "modules" {
    for_each = length(local.modules) > 0 ? ["modules"] : []
    command {
      command = local.modules_cmd[local.family[each.key]].command
      unless  = local.modules_cmd[local.family[each.key]].unless
    }
    notify = [handler.reload]
  }

  step "document_root" {
    for_each = local.roots
    directory {
      path = item.value
    }
  }

  step "include" {
    file {
      path    = local.l[each.key].include
      content = <<-EOT
        # Written by Conn3x. The config is in ${local.l[each.key].dir}/conn3x.conf.
        <IfDefine !conn3x_candidate>
            Include ${local.l[each.key].dir}/conn3x.conf
        </IfDefine>
        <IfDefine conn3x_candidate>
            Include ${local.l[each.key].dir}/conn3x.conf.candidate
        </IfDefine>
      EOT
    }
  }

  # The rendered config lands beside the live one first.
  step "candidate" {
    file {
      path    = "${local.l[each.key].dir}/conn3x.conf.candidate"
      content = local.rendered[each.key]
    }
  }

  # Copies the candidate over the live config only once Apache's config
  # test passes with it, so a typo or a missing certificate never reaches
  # the running server. Also puts it back after a hand edit to the live file.
  step "config" {
    command {
      command  = "${local.l[each.key].ctl} -t -D conn3x_candidate && install -m 644 ${local.l[each.key].dir}/conn3x.conf.candidate ${local.l[each.key].dir}/conn3x.conf"
      unless   = "[ \"$(sha256sum < ${local.l[each.key].dir}/conn3x.conf.candidate)\" = \"$(sha256sum < ${local.l[each.key].dir}/conn3x.conf)\" ]"
      triggers = { candidate = conn3x_file.apache__candidate[each.key].revision }
    }
    depends_on = [
      conn3x_file.apache_deb__ports,
      conn3x_command.apache_deb__default_site,
      conn3x_link.apache_deb__include,
      conn3x_line.apache_rpm__listen,
      conn3x_file.apache_rpm__ssl,
      conn3x_command.apache_rpm__network_connect,
      conn3x_command.apache_rpm__port,
      conn3x_command.apache_rpm__content,
    ]
    notify = [handler.reload]
  }

  step "running" {
    service {
      name    = local.l[each.key].service
      state   = "started"
      enabled = true
    }
  }

  # A graceful restart: children finish the requests they're serving on
  # the old config.
  handler "reload" {
    service {
      name   = local.l[each.key].service
      action = "reload"
    }
  }
}

# Debian and Ubuntu: Listen lines and a default site come with the package.
# The circuit's config sets its own Listen lines, which can't repeat one
# from ports.conf.
circuit "apache_deb" {
  hosts = local.deb_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "ports" {
    file {
      path    = "/etc/apache2/ports.conf"
      content = "# Written by Conn3x. The Listen lines are in /etc/apache2/conn3x.conf.\n"
    }
    depends_on = [conn3x_package.apache__package]
  }

  step "default_site" {
    command {
      command = "a2dissite -q 000-default"
      removes = "/etc/apache2/sites-enabled/000-default.conf"
    }
  }

  # What a2enconf zz-conn3x does.
  step "include" {
    link {
      path   = "/etc/apache2/conf-enabled/zz-conn3x.conf"
      target = "../conf-available/zz-conn3x.conf"
    }
  }
}

# The Red Hat family: httpd.conf has a Listen line, mod_ssl's ssl.conf
# another and a default virtual host, and SELinux decides which ports Apache
# may use and what it may read.
circuit "apache_rpm" {
  hosts = local.rpm_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "listen" {
    line {
      path   = "/etc/httpd/conf/httpd.conf"
      regexp = "^Listen "
      line   = "# Listen is set in /etc/httpd/conn3x.conf, written by Conn3x."
    }
    depends_on = [conn3x_package.apache__package]
  }

  # mod_ssl's settings for the server as a whole, without its Listen line
  # and default virtual host. That host's certificate is only made when
  # httpd first starts, so the config test fails without it.
  step "ssl" {
    for_each = local.need_ssl ? ["ssl"] : []
    file {
      path    = "/etc/httpd/conf.d/ssl.conf"
      content = <<-EOT
        # Written by Conn3x. The Listen lines and virtual hosts are in
        # /etc/httpd/conn3x.conf.
        SSLPassPhraseDialog exec:/usr/libexec/httpd-ssl-pass-dialog
        SSLSessionCache shmcb:/run/httpd/sslcache(512000)
        SSLSessionCacheTimeout 300
        SSLCryptoDevice builtin
        SSLHonorCipherOrder on
        SSLCipherSuite PROFILE=SYSTEM
        SSLProxyCipherSuite PROFILE=SYSTEM
      EOT
    }
    depends_on = [conn3x_command.apache__modules]
  }

  step "semanage" {
    for_each = length(local.selinux_ports) + length(local.roots) > 0 ? ["policycoreutils-python-utils"] : []
    package {
      name = item.value
    }
  }

  # Lets Apache connect to backends on any port, not only the web ports.
  step "network_connect" {
    for_each = local.need_proxy ? ["on"] : []
    command {
      command = "setsebool -P httpd_can_network_connect 1"
      unless  = "! selinuxenabled || getsebool httpd_can_network_connect | grep -q -- '--> on$'"
    }
  }

  step "port" {
    for_each = { for p in local.selinux_ports : tostring(p) => p }
    command {
      command = "semanage port -a -t http_port_t -p tcp ${item.value} 2>/dev/null || semanage port -m -t http_port_t -p tcp ${item.value}"
      unless  = "! selinuxenabled || semanage port -l | grep -E '^http_port_t ' | grep -Eq '[ ,]${item.value}(,|$)'"
    }
  }

  # Labels a document root outside /var/www so Apache may read it.
  step "content" {
    for_each = local.roots
    command {
      command = "semanage fcontext -a -t httpd_sys_content_t '${item.value}(/.*)?' && restorecon -R '${item.value}'"
      unless  = "! selinuxenabled || matchpathcon -n '${item.value}' | grep -q ':httpd_sys_content_t:'"
    }
    depends_on = [conn3x_directory.apache__document_root]
  }
}
