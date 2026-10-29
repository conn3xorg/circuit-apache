output "config" {
  description = "The config the circuit writes for Apache: Listen lines, extra_config and the virtual hosts. On the Red Hat family the file also loads the modules it names."
  value       = local.config
}
